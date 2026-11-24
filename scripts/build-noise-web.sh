#!/usr/bin/env bash
# Rebuild the flutter_rust_bridge web bundle for the Flutter client.
# The extra link args are required so the emitted wasm uses shared memory
# and exports the TLS entry points wasm-bindgen's worker pool needs.
set -euo pipefail
cd "$(dirname "$0")/../client"
flutter_rust_bridge_codegen build-web --wasm-pack-rustflags \
  "-C target-feature=+atomics,+bulk-memory,+mutable-globals \
   -C link-arg=--shared-memory \
   -C link-arg=--import-memory \
   -C link-arg=--max-memory=1073741824 \
   -C link-arg=--export-if-defined=__wasm_init_tls \
   -C link-arg=--export-if-defined=__tls_base \
   -C link-arg=--export-if-defined=__tls_size \
   -C link-arg=--export-if-defined=__tls_align"
