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
        
        # dpkg-sig wrapper - uses local script from tools directory
        dpkg-sig = pkgs.writeShellScriptBin "dpkg-sig" ''
          export PATH=${pkgs.lib.makeBinPath [ pkgs.dpkg pkgs.gnupg pkgs.perl ]}:$PATH
          exec ${pkgs.perl}/bin/perl ${./tools/dpkg-sig} "$@"
        '';
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
            dpkg
            dpkg-sig
          ];

        };
      }
    );
}
