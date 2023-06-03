{
  inputs = {
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    papermod = {
      url = "github:adityatelange/hugo-papermod";
      flake = false;
    };
  };

  outputs = inputs@{ flake-parts, papermod, self, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];

      perSystem = { pkgs, ... }:
        let
          inherit (pkgs)
            hugo
            mkShell
            stdenv
            ;
        in
        {
          devShells.default = mkShell {
            packages = [
              hugo
            ];

            env = {
              HUGO_MODULE_IMPORTS_PATH = "${papermod}";
            };
          };

          packages.default = stdenv.mkDerivation {
            pname = "blog";
            version = self.shortRev or "0000000";

            src = self;

            nativeBuildInputs = [ hugo ];

            env = {
              HUGO_MODULE_IMPORTS_PATH = "${papermod}";
              HUGO_PUBLISHDIR = placeholder "out";
            };

            buildPhase = ''
              hugo
            '';
          };
        };
    };
}
