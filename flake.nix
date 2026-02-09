{
  description = "GnosisVPN Linux package building";

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
            jq
            binutils
            nfpm
            help2man
            gzip
            gh
            deno
            google-cloud-sdk
          ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            curl
            openssl
          ];
          
          shellHook = ''
            alias ll='ls -al'
          '';

        };
      }
    );
}
