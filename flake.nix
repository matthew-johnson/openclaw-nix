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
      nixosModules.default = import ./modules/openclaw.nix;
      nixosModules.openclaw = import ./modules/openclaw.nix;
      overlays.default = final: prev: {
        openclaw = self.packages.${final.system}.openclaw;
      };

      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          nodejs = pkgs.nodejs_22;
          pnpm = pkgs.pnpm_10;
          version = "2026.4.8";
        in
        {
          openclaw = pkgs.stdenv.mkDerivation (finalAttrs: {
            pname = "openclaw";
            inherit version;

            # Use GitHub source so package.json and pnpm-lock.yaml match
            src = pkgs.fetchFromGitHub {
              owner = "openclaw";
              repo = "openclaw";
              tag = "v${version}";
              hash = "sha256-Y9FvI6Vhyi+kBLVio7/Qz77NWBViYMD0KheV7cXyeXs=";
            };

            nativeBuildInputs = [ 
              nodejs 
              pkgs.pnpmConfigHook
              pnpm 
              pkgs.jq 
              pkgs.makeWrapper 
              pkgs.python3 
              pkgs.pkg-config 
            ];
            buildInputs = with pkgs; [ vips ];

            pnpmDeps = pkgs.fetchPnpmDeps {
              inherit (finalAttrs) pname version src;
              pnpm = pnpm;
              fetcherVersion = 3;
              hash = "";  # Set to lib.fakeHash on first build, then replace with actual hash
            };

            buildPhase = ''
              runHook preBuild
              pnpm install --frozen-lockfile --offline --ignore-scripts
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
          });

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
