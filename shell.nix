{ pkgs ? import <nixpkgs> {} }:

let
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
pkgs.mkShell {
  buildInputs = [
    pkgs.emacs
    eldev
    pkgs.python313
    pkgs.uv
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
}
