{
  description = "hermes.el — Emacs client for the Hermes AI agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    hermes-agent.url = "github:NousResearch/hermes-agent";
  };

  outputs = { self, nixpkgs, flake-utils, hermes-agent }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        eldev = pkgs.stdenv.mkDerivation {
          pname = "eldev";
          version = "1.10";
          src = pkgs.fetchFromGitHub {
            owner = "doublep";
            repo = "eldev";
            rev = "1.10";
            sha256 = "sha256-9x9KaeMCf3Zyf/fTq/2HwMCM1uDrnvQsWUUcXq3R0ws=";
          };
          buildInputs = [ pkgs.emacs ];
          installPhase = ''
            mkdir -p $out/bin
            cp bin/eldev $out/bin/
            chmod +x $out/bin/eldev
          '';
        };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = [
            pkgs.emacs
            eldev
            hermes-agent.packages.${system}.default
          ];
          shellHook = ''
            echo "hermes.el development shell"
            echo "Run 'eldev test' to run tests"

            # If a local venv exists, expose it via HERMES_DEV_PYTHON so Emacs
            # picks it up automatically (see `hermes-rpc-python').
            if [ -x ".venv/bin/python" ]; then
              export HERMES_DEV_PYTHON="$PWD/.venv/bin/python"
              echo "Using venv python at $HERMES_DEV_PYTHON"
            fi
          '';
        };
      });
}
