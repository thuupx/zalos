#!/usr/bin/env bash
# Rebuild the zalos-noise wasm bindings for the Node server.
# Output lands in server/vendor/zalos-noise/ (committed).
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf server/vendor/zalos-noise
wasm-pack build crates/zalos-noise-wasm \
  --target nodejs \
  --out-dir ../../server/vendor/zalos-noise \
  --out-name zalos_noise
rm -f server/vendor/zalos-noise/.gitignore
