#!/usr/bin/env bash
# Run the headless E2E test
set -e
cd "$(dirname "$0")/.."
exec nix-shell --run \
  'eldev emacs --batch -L . -l hermes-mode -l hermes-render -l m2-check/e2e-test.el'
