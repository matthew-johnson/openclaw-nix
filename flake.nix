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
          openclaw = pkgs.buildNpmPackage {
            pname = "openclaw";
            inherit version;
            
            src = pkgs.fetchurl {
              url = "https://registry.npmjs.org/openclaw/-/openclaw-${version}.tgz";
              hash = "";
            };

            # Copy vendored package-lock.json
            postPatch = ''
              cp ${./package-lock.json} package-lock.json
            '';

            npmDepsHash = "sha256-0xFrsYvQvdJiKaYHM9zXT7VnlPtZ5KTMKqHIbQKHX48=";

            nativeBuildInputs = [ nodejs pkgs.makeWrapper pkgs.python3 pkgs.pkg-config ];
            buildInputs = with pkgs; [ vips ];

            # Don't run build scripts - tarball is pre-built
            npmInstallFlags = [ "--ignore-scripts" ];
            npmPackFlags = [ "--ignore-scripts" ];
            dontNpmBuild = true;

            # Fix npm hoisting: symlink channel extension deps to top-level
            postInstall = ''
              cd $out/lib/node_modules/openclaw
              
              for ext in slack telegram feishu discord bluebubbles matrix mattermost msteams; do
                extNodeModules="dist/extensions/$ext/node_modules"
                if [ -d "$extNodeModules" ]; then
                  for dep in "$extNodeModules"/*; do
                    depName=$(basename "$dep")
                    targetPath="node_modules/$depName"
                    
                    if [[ "$depName" == @* ]]; then
                      mkdir -p "$targetPath"
                      for subdep in "$dep"/*; do
                        subdepName=$(basename "$subdep")
                        if [ ! -e "$targetPath/$subdepName" ]; then
                          ln -s "$(realpath "$subdep")" "$targetPath/$subdepName"
                        fi
                      done
                    elif [ ! -e "$targetPath" ]; then
                      ln -s "$(realpath "$dep")" "$targetPath"
                    fi
                  done
                fi
              done
            '';

            installPhase = ''
              mkdir -p $out/lib/node_modules/openclaw
              cp -r . $out/lib/node_modules/openclaw/

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
            echo "  OpenClaw NixOS — buildNpmPackage + symlink fix"
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
