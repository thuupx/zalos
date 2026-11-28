# 3. Development workflow

> Tiếng Việt: [../vi/03-development.md](../vi/03-development.md) · Back to [index](README.md)

## 3.1 Pick a Zalo backend

| Mode | Command (in `server/`) | Talks to | Use it for |
|------|------------------------|----------|------------|
| **Fake** | `bun run src/cli.ts serve --dev --fake` | in-memory fake gateway | UI work, RPC work, daily development. No Zalo account needed. |
| **Mock** | `ZALOS_ZALO_MOCK_URL=http://127.0.0.1:7355 bun run src/cli.ts serve --dev` | offline WireMock Zalo (`mock/`) | exercising the real SDK/gateway code without Zalo |
| **Real** | a deployed server (see [Deployment](05-deployment.md)) | real Zalo | final verification only |

Default to **fake**. Use real Zalo as little as possible: every real login and
every extra request is a risk for that Zalo account (see
[Conventions](06-conventions.md#64-zalo-account-safety)).

`--dev` binds loopback only (`127.0.0.1`, `::1`, `localhost`) and refuses to run
under systemd. `--fake` is refused without `--dev`.

## 3.2 Local loop with the fake gateway

Terminal 1, the server:

```bash
cd server
export ZALOS_DATA_DIR=./data-dev        # keep dev state apart from anything else
bun run src/cli.ts serve --dev --fake
# zalos listening on ws://127.0.0.1:7443
# fake admin hook on 127.0.0.1:<port>
```

Terminal 2, a pairing code for your first (admin) device:

```bash
cd server
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts pair --role admin
```

Terminal 3, the client:

```bash
cd client
flutter run -d macos     # paste the zalos://pair?d=... URI on the pairing screen
```

Then in the app: **Me → Accounts → Add account**. The fake gateway answers the
QR login instantly with a "Fake Account".

Make the fake account receive messages:

```bash
cd server
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts accounts list         # find the slot
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts fake incoming <slot> <threadId> "hello from fake"
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts fake emit <slot> '<gateway event json>'
```

Reset everything: stop the server and delete `server/data-dev/`.

### Device notes

- **iOS simulator / macOS / Linux / Windows**: `127.0.0.1:7443` works directly.
- **Android emulator**: the emulator's `127.0.0.1` is itself. Forward the port:
  `adb reverse tcp:7443 tcp:7443`.
- **Physical phone**: use a deployed server on your tailnet, or run
  the server in local container mode (see [Deployment](05-deployment.md#53-local-container-mode)).
- **Web**: `scripts/build-noise-web.sh` once, then `scripts/dev-web.sh`
  (serves on `http://127.0.0.1:18934` with COOP/COEP). `localhost` counts as a
  secure context, so pairing works without HTTPS.

## 3.3 Offline mock of Zalo

```bash
docker compose -f mock/compose.yaml up -d --build     # gateway on 127.0.0.1:7355
cd server
ZALOS_ZALO_MOCK_URL=http://127.0.0.1:7355 bun run src/cli.ts serve --dev
bun run test:e2e                                       # e2e suite against the mock
```

Stubs live in `mock/wiremock/mappings/` (plain JSON, the part you edit). The
`mock/gateway/` service handles Zalo's encryption and the WebSocket. Read
[mock/README.md](../../../mock/README.md) before adding stubs. The mock proves
our integration, not real Zalo behavior.

## 3.4 Recipes

### Add an account-channel RPC method

1. **Gateway seam** (only if Zalo is involved): add the method to
   `ZaloGateway` (or `ZaloExtendedGateway`) in `server/src/gateway/types.ts`.
2. **Implement it** in `server/src/gateway/zca.ts` (via `@zalos/zalo-sdk`) and in
   `server/src/gateway/fake.ts` so dev mode and tests keep working. Add an OA
   implementation in `oa.ts` or make it throw a clear unsupported error.
3. **Business logic** in `server/src/accounts/manager.ts` if the action must be
   paced, persisted or broadcast (most writes). Append an event to the slot's log
   so other devices see the change.
4. **RPC handler** in `server/src/methods/account.ts` (or `account_extended.ts`):
   validate every param (`String(...)`, enums, sizes), use `slotOf(ctx)`, return a
   small JSON result.
5. **Tests** in `server/test/` (use the fake gateway helpers in `test/support/`).
   Run `bunx tsc --noEmit && bun test`.
6. **Client**: add the method to the service interface in
   `client/lib/src/domain/services.dart`, implement it in
   `client/lib/src/data/account_session.dart` with
   `_channel.request('<method>', {...})`, handle the event in the session's
   event switch, then wire UI/state.
7. **Strings**: every new user-visible text goes to both l10n tables (below).
8. Update [docs/DESIGN.md](../../DESIGN.md) if the RPC surface changed.

### Add or change a UI string

- Add the key to `client/lib/src/ui/l10n/strings_vi.dart` **and**
  `strings_en.dart`. Vietnamese is primary; `S.t()` falls back to it.
- Use `{0}`, `{1}` placeholders: `strings.t('loginScanned', [name])`.
- Never hardcode user-visible text in widgets.

### Change colors or spacing

Use tokens from `client/lib/src/ui/theme/tokens.dart` (`ZalosTokens.light` and
`.darkTokens`). Do not put raw `Color(0x...)` in widgets. The landing site
mirrors these tokens in `landing/src/app/globals.css`; keep them in sync if the
brand changes.

### Change the Rust crypto API

1. Edit the crate (`crates/zalos-noise` or `crates/zalos-vault`) and its tests:
   `cargo test -p zalos-noise -p zalos-vault`.
2. Server: `scripts/build-noise-wasm.sh` / `scripts/build-vault-wasm.sh`, commit
   `server/vendor/` output.
3. Client: update `client/rust/src/api/`, then `flutter_rust_bridge_codegen generate`
   in `client/`, and `scripts/build-noise-web.sh` for web.
4. Run all three test suites. Security-sensitive: ask for a second review.

### Add or fix a Zalo SDK endpoint

1. Find the real request shape (URL, method, params, headers) from a trusted
   capture. Do not guess parameters.
2. Implement it in the right `packages/zalo-sdk/src/apis/*.ts` module, reusing
   `ZaloHttpClient` helpers (`getEncrypted`, `postEncrypted`, `resolveEnvelope`).
3. Add a unit test in `packages/zalo-sdk/test/` with a mocked `fetch`.
4. Expose it through the gateway (recipe above).
5. Verify once against real Zalo with the smallest possible number of calls.

### Add a server environment variable

Read it in one place with a safe default, document it in
[Deployment](05-deployment.md#56-environment-variables) and in
`deploy/docker/compose*.yaml` if containers need it. Never use env vars for
secrets that end up in logs.

## 3.5 Before you open a PR

- [ ] Relevant tests added or updated, all suites for touched layers pass
- [ ] `flutter analyze` clean if the client changed
- [ ] Both l10n tables updated for new strings
- [ ] No secrets, tokens, cookies, `.env`, `server/data*` or captures staged
- [ ] Docs updated (DESIGN, onboarding) when behavior or setup changed
- [ ] Commit messages follow [Conventions](06-conventions.md#62-commits-and-branches)

Next: [4. Testing and CI](04-testing-and-ci.md).
