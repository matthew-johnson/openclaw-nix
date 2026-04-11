{
  description = "One flake. Fully hardened. Your agents, secured.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # NixOS module — import this in your configuration.nix
      nixosModules.default = import ./modules/openclaw.nix;
      nixosModules.openclaw = import ./modules/openclaw.nix;

      # Overlay that provides pkgs.openclaw
      overlays.default = final: prev: {
        openclaw = self.packages.${final.system}.openclaw;
      };

      # Standalone packages
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nodejs = pkgs.nodejs_22;
          pnpm = pkgs.pnpm_10;

          version = "2026.4.8";

          # Combine tarball + lockfile into a proper source
          openclawSrc = pkgs.stdenv.mkDerivation {
            name = "openclaw-src-${version}";
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
              hash = "sha256-skK9EgDWOosTMTZQOvFZ89l9njkCNFUPdoFZsKt4MBE=";
            };
            phases = [ "unpackPhase" "installPhase" ];
            installPhase = ''
              cp -r . $out
              # Use pnpm-lock.yaml instead of package-lock.json
              cp ${./pnpm-lock.yaml} $out/pnpm-lock.yaml
              # Remove package-lock.json to avoid conflicts
              rm -f $out/package-lock.json
            '';
            sourceRoot = "package";
          };

          openclawPkg = pkgs.stdenv.mkDerivation {
            pname = "openclaw";
            inherit version;

            src = openclawSrc;

            nativeBuildInputs = [ pnpm nodejs pkgs.jq pkgs.makeWrapper ];
            buildInputs = with pkgs; [ vips python3 pkg-config ];

            # Skip native compilation of optional deps
            pnpmFlags = [
              "--frozen-lockfile"
              "--ignore-scripts"
              "--no-optional"
            ];

            # Configure pnpm to use hoisted node_modules (flatter, works better with Nix)
            preBuild = ''
              export PNPM_HOME=$TMP/pnpm-store
              mkdir -p $PNPM_HOME
              pnpm config set store-dir $PNPM_HOME
              pnpm config set node-linker=hoisted
            '';

            buildPhase = ''
              pnpm install $pnpmFlags
            '';

            installPhase = ''
              mkdir -p $out/lib/node_modules/openclaw
              cp -r . $out/lib/node_modules/openclaw/

              cd $out/lib/node_modules/openclaw

              # Rebuild native modules
              pnpm rebuild @discordjs/opus sodium-native 2>/dev/null || true
              ${nodejs}/bin/node node_modules/sharp/install/check.js 2>/dev/null || true

              # Fix DAVE receive bug: replace carbon's bundled @discordjs/voice 0.19.0 with 0.19.2
              CARBON_VOICE="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@buape/carbon/node_modules/@discordjs/voice"
              TOP_VOICE="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@discordjs/voice"
              if [ -d "$CARBON_VOICE" ] && [ -d "$TOP_VOICE" ]; then
                rm -rf "$CARBON_VOICE"
                cp -r "$TOP_VOICE" "$CARBON_VOICE"
                echo "Patched @buape/carbon @discordjs/voice 0.19.0 -> 0.19.2"
              fi

              # Fix carbon module resolution
              CARBON_EXT="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@buape"
              CARBON_TOP="$out/lib/node_modules/openclaw/node_modules/@buape"
              if [ -d "$CARBON_EXT" ] && [ ! -d "$CARBON_TOP" ]; then
                mkdir -p "$out/lib/node_modules/openclaw/node_modules"
                cp -r "$CARBON_EXT" "$CARBON_TOP"
                echo "Linked @buape/carbon to top-level node_modules"
              fi

              # Fix AJV JSON Schema 2020-12 support for MCP tool validation
              sed -i 's|from "ajv"|from "ajv/dist/2020.js"|' $out/lib/node_modules/openclaw/node_modules/@mariozechner/pi-ai/dist/utils/validation.js

              mkdir -p $out/bin
              makeWrapper "${nodejs}/bin/node" "$out/bin/openclaw" \
                --add-flags "$out/lib/node_modules/openclaw/openclaw.mjs" \
                --prefix NODE_PATH "$out/lib/node_modules"
            '';

            meta = with pkgs.lib; {
              description = "OpenClaw — AI agent infrastructure platform";
              homepage = "https://github.com/openclaw/openclaw";
              license = licenses.mit;
              platforms = platforms.linux;
              mainProgram = "openclaw";
            };
          };
        in
        {
          openclaw = openclawPkg;

          quick-setup = pkgs.writeShellScriptBin "openclaw-setup" (builtins.readFile ./scripts/quick-setup.sh);

          default = pkgs.writeShellScriptBin "openclaw-nix" ''
            echo ""
            echo "  ╔══════════════════════════════════════════════════╗"
            echo "  ║  OpenClaw NixOS — Hardened Agent Infrastructure  ║"
            echo "  ║  One flake. Fully hardened. Your agents, secured ║"
            echo "  ╚══════════════════════════════════════════════════╝"
            echo ""
            echo "  Usage:"
            echo ""
            echo "    1. Add to your flake inputs:"
            echo "       openclaw.url = \"github:Scout-DJ/openclaw-nix\";"
            echo ""
            echo "    2. Import the module:"
            echo "       imports = [ openclaw.nixosModules.default ];"
            echo ""
            echo "    3. Enable it:"
            echo "       services.openclaw.enable = true;"
            echo "       services.openclaw.domain = \"agents.example.com\";"
            echo ""
            echo "    Quick setup (interactive):"
            echo "       nix run github:Scout-DJ/openclaw-nix#quick-setup"
            echo ""
            echo "    What you get:"
            echo "      ✓ OpenClaw gateway as hardened systemd service"
            echo "      ✓ Caddy reverse proxy with automatic TLS"
            echo "      ✓ Gateway auth enabled (auto-generated token)"
            echo "      ✓ Localhost-only binding (no exposed panels)"
            echo "      ✓ Tool allowlists (no 'full' mode)"
            echo "      ✓ Firewall: only 443 + SSH"
            echo "      ✓ Fail2ban for SSH"
            echo "      ✓ DynamicUser, PrivateTmp, NoNewPrivileges"
            echo ""
            echo "  Docs: https://github.com/Scout-DJ/openclaw-nix"
            echo ""
          '';
        });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/openclaw-nix";
        };
        quick-setup = {
          type = "app";
          program = "${self.packages.${system}.quick-setup}/bin/openclaw-setup";
        };
      });
    };
}
