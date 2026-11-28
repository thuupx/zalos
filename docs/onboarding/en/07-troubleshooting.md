# 7. Troubleshooting

> Tiếng Việt: [../vi/07-troubleshooting.md](../vi/07-troubleshooting.md) · Back to [index](README.md)

Each entry: symptom, cause, fix. Most of these were hit in real deployments.

## Web client

**Blank white page in every browser (iOS Safari/Chrome included).**
The CSP blocked something the Flutter web runtime needs. Open the browser
console. Known causes, all fixed in `server/src/web_static.ts` and the
Dockerfile:
- CanvasKit loaded from `www.gstatic.com` → build with
  `flutter build web --release --no-web-resources-cdn`.
- `flutter_rust_bridge` loads its wasm glue through `new Function(...)` → CSP
  needs `'unsafe-eval'` in `script-src`.
- `<base href="/">` rejected by `base-uri 'none'` → use `base-uri 'self'`.
- Font fallback from `fonts.gstatic.com` → allowed in `connect-src`.

**"SharedArrayBuffer is not defined" / pairing never completes on web.**
The page is not cross-origin isolated or not a secure context. Serve over HTTPS
(`tailscale serve`) or `localhost`, with COOP `same-origin` + COEP
`require-corp`. `http://100.x.y.z:7443` does not work.

**WebSocket test returns 404.** You tested `/` (not a tunnel route) or used
HTTP/2. Use `--http1.1` and `/v1/control`; expect `101`.

## Pairing

**"the server has not recorded a listen address; run `zalos serve` first".**
`zalos pair` reads the listen address the running server stored. Start the server
with the same `ZALOS_DATA_DIR` first.

**Code expired / already used.** Pairing codes are single use and expire after
10 minutes. Generate a new one.

**Device paired but sees no accounts.** New members have an empty ACL. An admin
grants slots in **Devices** (or `devices.setAcl`).

**Android emulator cannot connect to a dev server.** Run
`adb reverse tcp:7443 tcp:7443`.

## Zalo login

**QR login fails immediately with `Truy cập không hợp lệ` (error -4).**
`id.zalo.me` rejects QR requests without its login page as `Origin`/`Referer`.
Fixed in `packages/zalo-sdk/src/auth/login-qr.ts` (`ID_PAGE_HEADERS`). If it
returns, compare our headers with what the official web login sends.

**Phone confirms the login but zalos says it failed
(`Failed to confirm logged-in state via /jr/userinfo`).** Session cookies set by
`id.zalo.me` for `chat.zalo.me` were dropped by a strict cookie jar. Fixed in
`packages/zalo-sdk/src/core/cookies.ts`. The error now includes the redirect
hops and cookie names; read them in `docker logs` before retrying.

**QR expires before you can scan.** Zalo QR codes live about 100 seconds and the
app renews them automatically. A screenshot of an old QR is useless. If zalos
runs on the same phone as Zalo, open zalos on another screen (desktop or web) or
use Zalo's "scan from photo" quickly.

**Account goes offline repeatedly.** Zalo allows one web session per account.
Someone opened Zalo Web (or PC in web mode) for that account; the server waits
`ZALOS_ZCA_DISPLACED_MS` and reconnects. Close the other web session.

## Builds

**First Docker build takes very long.** Expected: it compiles wasm-pack,
flutter_rust_bridge_codegen, the Rust wasm bundle and Flutter web. Run it under
`nohup` on small machines and watch the log.

**`web/pkg` missing.** Run `scripts/build-noise-web.sh` once (nightly Rust with
`rust-src` and the `wasm32-unknown-unknown` target).

**Dart bindings out of date after a Rust change.** Run
`flutter_rust_bridge_codegen generate` in `client/`; versions must match
(2.12.0).

**macOS release build complains about keychain entitlements.** See
`client/README.md` "macOS signing": unsigned builds use the login keychain.

## Servers without git (e.g. Synology NAS)

Use git through a container, for example a wrapper script:

```sh
#!/bin/sh
exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":"$PWD" -w "$PWD" alpine/git:latest "$@"
```

Put it first on `PATH` when you `git pull` on the NAS.

Back to the [index](README.md).
