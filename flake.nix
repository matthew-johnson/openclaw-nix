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

          # Combine tarball + pnpm-lock.yaml into source
          openclawSrc = pkgs.stdenv.mkDerivation {
            name = "openclaw-src-${version}";
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
              hash = "sha256-skK9EgDWOosTMTZQOvFZ89l9njkCNFUPdoFZsKt4MBE=";
            };
            phases = [ "unpackPhase" "installPhase" ];
            installPhase = ''
              cp -r . $out
              cp ${./pnpm-lock.yaml} $out/pnpm-lock.yaml
              rm -f $out/package-lock.json
            '';
            sourceRoot = "package";
          };
        in
        {
          openclawPkg = pkgs.stdenv.mkDerivation {
            pname = "openclaw";
            inherit version;
            src = openclawSrc;
            
            # Set environment variables for all phases
            HOME = "/tmp";
            PNPM_HOME = "/tmp/pnpm-store";
            XDG_CACHE_HOME = "/tmp/cache";
            XDG_DATA_HOME = "/tmp/data";
            XDG_CONFIG_HOME = "/tmp/config";

            nativeBuildInputs = [ pnpm nodejs pkgs.jq pkgs.makeWrapper pkgs.python3 pkgs.pkg-config ];
            buildInputs = with pkgs; [ vips ];

            buildPhase = ''
              runHook preBuild
              
              mkdir -p $HOME $PNPM_HOME $XDG_CACHE_HOME $XDG_DATA_HOME $XDG_CONFIG_HOME
              
              pnpm config set store-dir $PNPM_HOME --global
              pnpm config set node-linker hoisted --global
              pnpm install --frozen-lockfile --ignore-scripts
            '';

            installPhase = ''
              mkdir -p $out/lib/node_modules/openclaw
              cp -r . $out/lib/node_modules/openclaw/

              cd $out/lib/node_modules/openclaw

              # Rebuild native modules
              pnpm rebuild @discordjs/opus sodium-native 2>/dev/null || true
              ${nodejs}/bin/node node_modules/sharp/install/check.js 2>/dev/null || true

              # Fix DAVE receive bug
              CARBON_VOICE="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@buape/carbon/node_modules/@discordjs/voice"
              TOP_VOICE="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@discordjs/voice"
              if [ -d "$CARBON_VOICE" ] && [ -d "$TOP_VOICE" ]; then
                rm -rf "$CARBON_VOICE"
                cp -r "$TOP_VOICE" "$CARBON_VOICE"
              fi

              # Fix carbon module resolution
              CARBON_EXT="$out/lib/node_modules/openclaw/dist/extensions/discord/node_modules/@buape"
              CARBON_TOP="$out/lib/node_modules/openclaw/node_modules/@buape"
              if [ -d "$CARBON_EXT" ] && [ ! -d "$CARBON_TOP" ]; then
                mkdir -p "$out/lib/node_modules/openclaw/node_modules"
                cp -r "$CARBON_EXT" "$CARBON_TOP"
              fi

              # Fix AJV JSON Schema 2020-12 support
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

          quick-setup = pkgs.writeShellScriptBin "openclaw-setup" (builtins.readFile ./scripts/quick-setup.sh);

          default = pkgs.writeShellScriptBin "openclaw-nix" ''
            echo ""
            echo "  OpenClaw NixOS — pnpm build"
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
