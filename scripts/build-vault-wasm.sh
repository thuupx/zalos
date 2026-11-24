#!/usr/bin/env bash
# Rebuild the zalos-vault wasm bindings for the Bun server.
# Output lands in server/vendor/zalos-vault/ (committed).
set -euo pipefail
cd "$(dirname "$0")/.."
rm -rf server/vendor/zalos-vault
wasm-pack build crates/zalos-vault-wasm \
  --target nodejs \
  --out-dir ../../server/vendor/zalos-vault \
  --out-name zalos_vault
rm -f server/vendor/zalos-vault/.gitignore
