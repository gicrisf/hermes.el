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

            # The upstream hermes-agent package bundles its own Python
            # environment.  Extract it from the wrapper so Emacs can spawn
            # `python -m tui_gateway.entry' with the right interpreter.
            HERMES_BIN=$(command -v hermes)
            if [ -n "$HERMES_BIN" ]; then
              HERMES_PY=$(grep -o "HERMES_PYTHON='[^']*'" "$HERMES_BIN" 2>/dev/null | cut -d"'" -f2)
              if [ -n "$HERMES_PY" ] && [ -x "$HERMES_PY" ]; then
                export HERMES_DEV_PYTHON="$HERMES_PY"
                echo "Using hermes-agent python at $HERMES_DEV_PYTHON"
              fi
            fi
          '';
        };
      });
}
