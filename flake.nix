{
  description = "GnosisVPN Linux package building";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, treefmt-nix }:
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";

          programs.deno.enable = true;
          programs.nixpkgs-fmt.enable = true;
          # will mess up too many of the generated scripts
          # programs.shellcheck.enable = true;
          programs.shfmt.enable = true;
          programs.yamlfmt.enable = true;

          settings.formatter.deno.excludes = [ "*.yaml" "*.yml" ];

          settings.formatter.yamlfmt.excludes = [ "linux/nfpm-template.yaml" ];

          settings.formatter.yamlfmt.settings = {
            formatter.type = "basic";
            formatter.max_line_length = 120;
            formatter.trim_trailing_whitespace = true;
            formatter.include_document_start = true;
          };
        };
      in
      {
        formatter = treefmtEval.config.build.wrapper;
        checks = {
          formatting = treefmtEval.config.build.check self;
        };

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
