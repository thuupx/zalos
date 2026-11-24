#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../client"
if [[ ! -d web/pkg ]]; then
  echo "Missing web/pkg. Run scripts/build-noise-web.sh once before starting the dev server." >&2
  exit 1
fi
exec "${FLUTTER_BIN:-flutter}" run -d web-server \
  --web-hostname=127.0.0.1 \
  --web-port="${PORT:-18934}" \
  --web-header='Cross-Origin-Opener-Policy=same-origin' \
  --web-header='Cross-Origin-Embedder-Policy=require-corp' \
  "$@"
