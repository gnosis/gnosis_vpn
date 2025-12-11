{
  description = "Development environment for GnosisVPN Linux package building";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            just
            gnupg
            curl
            binutils
            nfpm
            help2man
            gzip
            gh
            google-cloud-sdk
            # Debian packaging tools
            dpkg
            # Archive tools
            libarchive  # provides bsdtar and bsdcpio (includes ar functionality)
          ];
          
          shellHook = ''
            alias ll='ls -al'
            
            # Install Debian packaging tools on Linux if not already installed
            if [[ "$(uname -s)" == "Linux" ]]; then
              MISSING_PKGS=()
              command -v dh &>/dev/null || MISSING_PKGS+=(debhelper)
              command -v debsign &>/dev/null || MISSING_PKGS+=(devscripts)
              command -v dput &>/dev/null || MISSING_PKGS+=(dput)
              
              if [ ''${#MISSING_PKGS[@]} -gt 0 ]; then
                echo "📦 Installing Debian tools: ''${MISSING_PKGS[*]} (requires sudo)..."
                sudo apt-get update -qq && sudo apt-get install -y "''${MISSING_PKGS[@]}"
              fi
            fi
          '';

        };
      }
    );
}
