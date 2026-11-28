# 1. Setup

> Tiếng Việt: [../vi/01-setup.md](../vi/01-setup.md) · Back to [index](README.md)

Goal of this page: by the end you have every layer building and its tests
passing on your machine.

## 1.1 Toolchains

| Tool | Version | Needed for | Install |
|------|---------|------------|---------|
| Git | any recent | everything | system package |
| Bun | **1.4.4** or newer 1.4.x (`engines.bun >= 1.4`) | server, SDK, mock, landing | `curl -fsSL https://bun.sh/install \| bash` |
| Rust | stable via `rustup` | crates, client FFI | `curl https://sh.rustup.rs -sSf \| sh` |
| Rust nightly + `rust-src` + `wasm32-unknown-unknown` | nightly | web client wasm only | `rustup toolchain install nightly --component rust-src && rustup target add --toolchain nightly wasm32-unknown-unknown` |
| wasm-pack | **0.15.1** | rebuilding server wasm and web client wasm | `cargo install --locked --version 0.15.1 wasm-pack` |
| flutter_rust_bridge_codegen | **2.12.0** (must match `client/pubspec.yaml`) | regenerating Dart bindings, web wasm | `cargo install --locked --version 2.12.0 flutter_rust_bridge_codegen` |
| Flutter | **3.50.x** stable (the Docker image pins 3.50.1) | client | https://docs.flutter.dev/get-started |
| Xcode | current | iOS / macOS builds | App Store |
| Android SDK + NDK | current | Android builds | Android Studio |
| Docker + Compose v2 | current | deployment, mock Zalo, e2e | Docker Desktop / OrbStack / distro packages |
| Tailscale | current | real deployments | https://tailscale.com/download |

On Apple Silicon, Flutter release (AOT) builds also need Rosetta 2:
`softwareupdate --install-rosetta`.

Check what you have:

```bash
bun --version && cargo --version && flutter --version && docker compose version
```

## 1.2 Clone

```bash
git clone git@github.com:thuupx/zalos.git
cd zalos
```

There is no root package manager. Each layer installs its own dependencies.

## 1.3 Rust crates

```bash
cargo test -p zalos-noise -p zalos-vault
```

These crates hold **all** cryptography. TypeScript and Dart never implement
crypto by hand; they call these crates (wasm on the server and web, native FFI
on other clients).

The server uses committed wasm builds in `server/vendor/`. You only rebuild them
when you change a crate:

```bash
scripts/build-noise-wasm.sh   # -> server/vendor/zalos-noise/
scripts/build-vault-wasm.sh   # -> server/vendor/zalos-vault/
```

Commit the regenerated `server/vendor/` output together with the crate change.

## 1.4 Zalo SDK

```bash
cd packages/zalo-sdk
bun install
bun test
```

`@zalos/zalo-sdk` is consumed by the server as `file:../packages/zalo-sdk`.

## 1.5 Server

```bash
cd server
bun install --frozen-lockfile
bunx tsc --noEmit          # typecheck
bun test                   # ~390 tests, about 45 s
```

The CLI entry is `server/src/cli.ts` (`bun run src/cli.ts <command>`, or the
`zalos` binary inside the Docker image):

| Command | Purpose |
|---------|---------|
| `serve [--dev] [--fake] [--local] [--port N] [--host H]` | Run the server. |
| `pair [--role admin\|member]` | Print a pairing URI and terminal QR. |
| `doctor` | Run the host/container hardening checks. |
| `health` | Container healthcheck (TCP connect to the listen address). |
| `devices list [--all] \| revoke [--force] <id>` | Manage paired devices. |
| `accounts list \| add \| add-oa \| remove <slot>` | Manage Zalo accounts (`add` = QR login in the terminal). |
| `fake incoming <slot> <threadId> <text> \| fake emit <slot> <json>` | Inject events into the fake gateway (dev only). |
| `vault reset --yes` | Destroy vault state (dangerous). |

Data lives in `ZALOS_DATA_DIR` (default `./data`): SQLite database, server
static key, temporary uploads. **Never commit `server/data/`.**

## 1.6 Flutter client

```bash
cd client
flutter pub get
flutter analyze
flutter test
flutter run -d macos        # or an iOS simulator, Android emulator, linux, windows
```

Native builds compile `client/rust` automatically through the `rust_builder/`
plugin (cargokit), which also runs `rustup target add` for missing targets.

Web needs the flutter_rust_bridge wasm bundle first (nightly Rust, see 1.1):

```bash
scripts/build-noise-web.sh    # builds client/web/pkg/
scripts/dev-web.sh            # flutter run -d web-server on 127.0.0.1:18934 with COOP/COEP headers
```

The web client needs **cross-origin isolation** (SharedArrayBuffer), so always
serve it with `Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: require-corp`, from `localhost` or HTTPS.
`scripts/dev-web.sh` and `scripts/serve-web.sh` already do that.

After changing the Rust API in `client/rust/src/api/`, regenerate bindings:

```bash
cd client && flutter_rust_bridge_codegen generate
```

## 1.7 Landing site (optional)

```bash
cd landing
bun install
bun run dev     # http://localhost:3000
bun run lint && bun run build
```

## 1.8 Done checklist

- [ ] `cargo test -p zalos-noise -p zalos-vault` passes
- [ ] `packages/zalo-sdk`: `bun test` passes
- [ ] `server`: `bunx tsc --noEmit` and `bun test` pass
- [ ] `client`: `flutter analyze` is clean and `flutter test` passes
- [ ] You can launch the client on at least one platform

Next: [2. Architecture](02-architecture.md).
