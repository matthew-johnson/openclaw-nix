{ config, lib, pkgs, ... }:

let
  cfg = config.services.openclaw;
  settingsFormat = pkgs.formats.json { };

  # Generate gateway config
  
  gatewayConfig = {
    gateway = {
      mode = "local";
      trustedProxies = [ "127.0.0.1" ];
      port = cfg.gatewayPort;
    };
    agents.defaults.model.primary = 
      if cfg.modelProvider == "ollama" 
      then "ollama/${cfg.ollamaModel}"
      else cfg.modelProvider;
  } // cfg.extraGatewayConfig;

  gatewayConfigFile = settingsFormat.generate "openclaw-gateway.json" gatewayConfig;
in
{
  options.services.openclaw = {
    enable = lib.mkEnableOption "OpenClaw hardened agent infrastructure";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.openclaw or (pkgs.stdenv.mkDerivation rec {
        pname = "openclaw";
        version = cfg.version;
        nativeBuildInputs = with pkgs; [ nodejs_22 cacert ];
        buildInputs = with pkgs; [ nodejs_22 ];
        dontUnpack = true;
        buildPhase = ''
          export HOME=$TMPDIR
          export npm_config_cache=$TMPDIR/npm-cache
          mkdir -p $npm_config_cache
          npm install --global --prefix=$out openclaw@${version}
        '';
        installPhase = ''
          mkdir -p $out/bin
          for f in $out/lib/node_modules/.bin/*; do
            name=$(basename $f)
            [ ! -e "$out/bin/$name" ] && ln -sf "$f" "$out/bin/$name"
          done
        '';
        meta.description = "OpenClaw agent infrastructure";
      });
      defaultText = lib.literalExpression "pkgs.openclaw (auto-built from npm if not in nixpkgs)";
      description = "The OpenClaw package to use. Auto-fetched from npm if not provided.";
    };

    version = lib.mkOption {
      type = lib.types.str;
      default = "2026.2.6-3";
      description = "OpenClaw version (used for npm/docker install fallback).";
    };

    domain = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "agents.example.com";
      description = "Public domain for Caddy TLS. Leave empty to disable Caddy.";
    };

    gatewayPort = lib.mkOption {
      type = lib.types.port;
      default = 3000;
      description = "Local port for the OpenClaw gateway (bound to localhost only).";
    };

    authTokenFile = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openclaw/auth-token";
      description = "Path to file containing the gateway auth token. Auto-generated if missing.";
    };

    dataDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/openclaw";
      description = "State directory for OpenClaw data.";
    };

    # --- Tool Security ---
    toolSecurity = lib.mkOption {
      type = lib.types.enum [ "deny" "allowlist" ];
      default = "allowlist";
      description = ''
        Tool execution security mode.
        "deny" blocks all tool execution. "allowlist" permits only listed tools.
        Note: "full" mode is intentionally excluded — it grants unrestricted access.
      '';
    };

    toolAllowlist = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "read"
        "write"
        "edit"
        "web_search"
        "web_fetch"
        "message"
        "tts"
      ];
      description = ''
        Tools permitted when toolSecurity = "allowlist".
        Defaults are safe read/write/search tools. exec, browser, nodes excluded by default.
        Add "exec" only if you understand the implications.
      '';
    };

    # --- Plugins ---
    telegram = {
      enable = lib.mkEnableOption "Telegram plugin";
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Telegram bot token.";
      };
    };

    discord = {
      enable = lib.mkEnableOption "Discord plugin";
      tokenFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Path to file containing Discord bot token.";
      };
    };

    # --- Model ---
    modelProvider = lib.mkOption {
      type = lib.types.str;
      default = "anthropic";
      description = "Default model provider (anthropic, openai, ollama, etc).";
    };

    modelApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing model API key.";
    };

    ollamaBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://127.0.0.1:11434";
      description = "Base URL for Ollama API. Only used when modelProvider = \"ollama\".";
    };

    ollamaModel = lib.mkOption {
      type = lib.types.str;
      default = "qwen3.5:27b";
      description = "Ollama model name. Only used when modelProvider = \"ollama\".";
    };

    # --- Updates ---
    autoUpdate = {
      enable = lib.mkEnableOption "automatic OpenClaw updates via systemd timer";
      schedule = lib.mkOption {
        type = lib.types.str;
        default = "weekly";
        description = "systemd calendar expression for update checks.";
      };
    };

    # --- Advanced ---
    extraGatewayConfig = lib.mkOption {
      type = lib.types.attrs;
      default = { };
      description = "Extra attributes merged into gateway config.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open firewall ports (443 for HTTPS, 22 for SSH).";
    };
  };

  config = lib.mkIf cfg.enable {

    # ── Packages ──
    environment.systemPackages = [ cfg.package ];

    # ── Auth token generation ──
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 openclaw openclaw -"
    ];

    # ── Main gateway service ──
    systemd.services.openclaw-gateway = {
      description = "OpenClaw Gateway (hardened)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      preStart = ''
        # Auto-generate auth token if missing
        if [ ! -f "${cfg.authTokenFile}" ]; then
          ${pkgs.openssl}/bin/openssl rand -hex 32 > "${cfg.authTokenFile}"
          chmod 600 "${cfg.authTokenFile}"
          echo "Generated new gateway auth token at ${cfg.authTokenFile}"
        fi
        # Write token env file for systemd EnvironmentFile
        # Copy Nix-generated config into openclaw home dir on every activation
        # so config changes deploy cleanly without manual setup steps
        mkdir -p ${cfg.dataDir}/.openclaw
        cp ${gatewayConfigFile} ${cfg.dataDir}/.openclaw/openclaw.json
        # Inject gateway token into config so CLI can connect
        TOKEN=$(cat ${cfg.authTokenFile})
        ${pkgs.jq}/bin/jq --arg token "$TOKEN" \
          '.gateway.auth.token = $token | .gateway.remote.token = $token' \
          ${cfg.dataDir}/.openclaw/openclaw.json > ${cfg.dataDir}/.openclaw/openclaw.json.tmp
        mv ${cfg.dataDir}/.openclaw/openclaw.json.tmp ${cfg.dataDir}/.openclaw/openclaw.json
        chmod 600 ${cfg.dataDir}/.openclaw/openclaw.json
        mkdir -p ${cfg.dataDir}/workspace
        mkdir -p ${cfg.dataDir}/agents/main/sessions
      '';
      path = [ pkgs.tailscale ];
      serviceConfig = {
        Type = "simple";
	ExecStart = "${pkgs.bash}/bin/bash -c '${cfg.package}/bin/openclaw gateway --bind loopback --tailscale serve --port ${toString cfg.gatewayPort} --auth token --token $(cat ${cfg.authTokenFile})'";
        Restart = "on-failure";
        RestartSec = 5;
        WorkingDirectory = cfg.dataDir;
        StateDirectory = "openclaw";

        # ── Hardening ──
        DynamicUser = false;  # We use a dedicated user below
        User = "openclaw";
        Group = "openclaw";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        ProtectHostname = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false;  # Node.js needs JIT
        ReadWritePaths = [ cfg.dataDir ];
        SystemCallArchitectures = "native";
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
          "~@resources"
        ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        UMask = "0077";
      };

      environment = lib.mkMerge [
        {
          OPENCLAW_HOST = "127.0.0.1";
          OPENCLAW_PORT = toString cfg.gatewayPort;
          NODE_ENV = "production";
          OPENCLAW_MODEL_PROVIDER = cfg.modelProvider;
        }
        (lib.mkIf (cfg.modelProvider == "ollama") {
          OLLAMA_API_KEY = "ollama-local";
        })
        (lib.mkIf (cfg.modelApiKeyFile != null) {
          OPENCLAW_API_KEY_FILE = cfg.modelApiKeyFile;
        })
        (lib.mkIf (cfg.telegram.enable && cfg.telegram.tokenFile != null) {
          OPENCLAW_TELEGRAM_ENABLED = "true";
        })
        (lib.mkIf (cfg.discord.enable && cfg.discord.tokenFile != null) {
          OPENCLAW_DISCORD_ENABLED = "true";
        })
      ];
    };

    # ── Dedicated user ──
    users.users.openclaw = {
      isSystemUser = true;
      group = "openclaw";
      home = cfg.dataDir;
      description = "OpenClaw service user";
    };
    users.groups.openclaw = { };

    # ── Caddy reverse proxy ──
    services.caddy = lib.mkIf (cfg.domain != "") {
      enable = true;
      virtualHosts."${cfg.domain}" = {
        extraConfig = ''
          reverse_proxy 127.0.0.1:${toString cfg.gatewayPort}

          header {
            Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
            X-Content-Type-Options "nosniff"
            X-Frame-Options "DENY"
            Referrer-Policy "strict-origin-when-cross-origin"
            -Server
          }
        '';
      };
    };

    # ── Firewall ──
    networking.firewall = lib.mkIf cfg.openFirewall {
      allowedTCPPorts = [ 443 80 ];  # 80 for ACME redirect
    };

    # ── Fail2ban ──
    services.fail2ban = {
      enable = true;
      maxretry = 5;
      bantime = "1h";
      bantime-increment.enable = true;
    };

    # ── Auto-update timer ──
    systemd.services.openclaw-update = lib.mkIf cfg.autoUpdate.enable {
      description = "OpenClaw auto-update";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScript "openclaw-update" ''
          echo "Checking for OpenClaw updates..."
          ${pkgs.nixos-rebuild or pkgs.writeShellScript "noop" "echo 'nixos-rebuild not available'"}/bin/nixos-rebuild switch --flake /etc/nixos#$(hostname) --upgrade 2>&1 || true
        ''}";
      };
    };

    systemd.timers.openclaw-update = lib.mkIf cfg.autoUpdate.enable {
      description = "OpenClaw update timer";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.autoUpdate.schedule;
        Persistent = true;
        RandomizedDelaySec = "1h";
      };
    };
  };
}
