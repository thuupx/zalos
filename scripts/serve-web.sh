#!/usr/bin/env bash
# Serve client/build/web on :18934 with the cross-origin isolation headers
# that flutter_rust_bridge's web worker pool (SharedArrayBuffer) requires.
set -euo pipefail
cd "$(dirname "$0")/../client/build/web"
exec bun -e '
Bun.serve({
  port: 18934,
  hostname: "127.0.0.1",
  async fetch(req) {
    const path = new URL(req.url).pathname === "/" ? "/index.html" : new URL(req.url).pathname;
    const file = Bun.file("." + path);
    if (!(await file.exists())) return new Response("not found", { status: 404 });
    const response = new Response(file);
    response.headers.set("Cross-Origin-Opener-Policy", "same-origin");
    response.headers.set("Cross-Origin-Embedder-Policy", "require-corp");
    response.headers.set("Cache-Control", "no-store");
    response.headers.set("X-Frame-Options", "DENY");
    response.headers.set("X-Content-Type-Options", "nosniff");
    response.headers.set("Referrer-Policy", "no-referrer");
    response.headers.set(
      "Content-Security-Policy",
      "default-src \x27self\x27; script-src \x27self\x27 \x27wasm-unsafe-eval\x27; style-src \x27self\x27 \x27unsafe-inline\x27; img-src \x27self\x27 blob: data:; media-src \x27self\x27 blob:; connect-src \x27self\x27 ws: wss:; frame-ancestors \x27none\x27; base-uri \x27none\x27",
    );
    return response;
  },
});
console.log("serving on http://127.0.0.1:18934");
'
