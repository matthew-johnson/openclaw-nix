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
          version = "2026.4.8";
        in
        {
          openclaw = pkgs.stdenv.mkDerivation {
            pname = "openclaw";
            inherit version;
            
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
              hash = "sha256-skK9EgDWOosTMTZQOvFZ89l9njkCNFUPdoFZsKt4MBE=";
            };

            sourceRoot = "package";

            nativeBuildInputs = [ nodejs pkgs.makeWrapper pkgs.python3 pkgs.pkg-config ];
            buildInputs = with pkgs; [ vips ];

            installPhase = ''
              mkdir -p $out/lib/node_modules/openclaw
              cp -r . $out/lib/node_modules/openclaw/
              cd $out/lib/node_modules/openclaw

              # Rebuild native modules
              npm rebuild @discordjs/opus sodium-native 2>/dev/null || true

              # Fix npm hoisting: symlink channel extension deps to top-level
              for ext in slack telegram feishu discord bluebubbles matrix mattermost msteams; do
                extNodeModules="dist/extensions/$ext/node_modules"
                if [ -d "$extNodeModules" ]; then
                  for dep in "$extNodeModules"/*; do
                    depName=$(basename "$dep")
                    targetPath="node_modules/$depName"
                    
                    # Handle scoped packages (@org/package)
                    if [[ "$depName" == @* ]]; then
                      # depName is like @slack, dep contains bolt, logger, etc.
                      mkdir -p "$targetPath"
                      for subdep in "$dep"/*; do
                        subdepName=$(basename "$subdep")
                        if [ ! -e "$targetPath/$subdepName" ]; then
                          ln -s "$(realpath "$subdep")" "$targetPath/$subdepName"
                        fi
                      done
                    elif [ ! -e "$targetPath" ]; then
                      # Regular package
                      ln -s "$(realpath "$dep")" "$targetPath"
                    fi
                  done
                fi
              done

              mkdir -p $out/bin
              makeWrapper "${nodejs}/bin/node" "$out/bin/openclaw" \
                --add-flags "$out/lib/node_modules/openclaw/dist/entry.mjs" \
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
            echo "  OpenClaw NixOS — npm + symlink fix"
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
