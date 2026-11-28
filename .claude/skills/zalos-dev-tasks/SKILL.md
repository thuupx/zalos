---
name: zalos-dev-tasks
description: Step-by-step playbooks for common code changes in the zalos repo - adding an RPC method end to end (gateway, AccountManager, methods, Flutter AccountSession), adding UI strings to both l10n tables, changing theme tokens, changing the Rust Noise/vault API and regenerating wasm and flutter_rust_bridge bindings, adding a Zalo SDK endpoint, adding a server env var, and the checks to run before committing. Use when implementing or reviewing a feature or fix in server/, client/, packages/zalo-sdk/, crates/ or deploy/.
---

# zalos development tasks

Full recipes with context: `docs/onboarding/en/03-development.md` (§3.4) and
`docs/onboarding/vi/03-development.md`. Conventions: `06-conventions.md`.
Read the relevant recipe, then follow the checklist below.

## Playbooks

### New account RPC method
1. `server/src/gateway/types.ts`: extend `ZaloGateway`/`ZaloExtendedGateway` (only if Zalo is called).
2. Implement in `server/src/gateway/zca.ts` **and** `server/src/gateway/fake.ts`; OA in `oa.ts` or a clear unsupported error.
3. Writes that must be paced/persisted/broadcast go through `server/src/accounts/manager.ts` and append an event to the slot log.
4. Handler in `server/src/methods/account.ts` (or `account_extended.ts`): validate every param, use `slotOf(ctx)`.
5. Tests in `server/test/` with `test/support/helpers.ts` + `client.ts`.
6. Client: interface in `client/lib/src/domain/services.dart`, implementation in `client/lib/src/data/account_session.dart` (`_channel.request(...)`, event handling), then UI/state.
7. Update `docs/DESIGN.md` if the RPC surface changed.

### UI string
Add the key to `client/lib/src/ui/l10n/strings_vi.dart` and `strings_en.dart`
(Vietnamese is primary and the fallback). Use `{0}` placeholders with `S.t(key, [args])`.

### Colors / theme
Edit `client/lib/src/ui/theme/tokens.dart` (light and dark). If the brand
palette changes, mirror it in `landing/src/app/globals.css`.

### Rust crypto API
Crate + tests → `scripts/build-noise-wasm.sh` / `scripts/build-vault-wasm.sh`
(commit `server/vendor/`) → `client/rust/src/api/` →
`flutter_rust_bridge_codegen generate` in `client/` → `scripts/build-noise-web.sh`.
Security-sensitive: flag it for an extra reviewer.

### Zalo SDK endpoint
Use a real captured request shape (never guess params or headers), implement in
`packages/zalo-sdk/src/apis/*.ts` with `ZaloHttpClient` helpers
(`getEncrypted`, `postEncrypted`, `resolveEnvelope`), unit test with mocked
`fetch` in `packages/zalo-sdk/test/`, expose through the gateway.

### Server env var
Read once with a safe default, document in `05-deployment.md` (both languages)
and in `deploy/docker/compose*.yaml` if containers need it.

## Checks (run what the change touches)

```bash
cargo test -p zalos-noise -p zalos-vault                      # crates/
(cd packages/zalo-sdk && bun test)                             # SDK
(cd server && bunx tsc --noEmit && bun test)                   # server
(cd server && bun run test:e2e)                                # needs mock/compose.yaml running
(cd client && flutter analyze && flutter test)                 # client
(cd landing && bun run lint && bun run build)                  # landing
```

For a bug fix, add a test that fails before the fix and passes after it.

## Rules that block a merge

- Zalo safety: no extra Zalo calls per user action, keep the per-account send
  queue, mimic the official client's requests exactly, develop on the fake
  gateway or mock, touch real Zalo only for final verification.
- Security: no secrets staged (`.env`, `server/data*/`, cookies, pairing URIs,
  `.research/`); do not weaken doctor checks, container hardening, CSP/COOP/COEP,
  the SSRF guard or role/ACL checks without a documented, reviewed reason.
- Crypto only in Rust; never edit generated bindings in `client/lib/src/rust_lib/`.
- Code, comments, commits and docs in English, except the bilingual onboarding
  guide (update both languages). Commits use Conventional Commits
  (`feat:`, `fix:`, `docs:`, `chore:` ...).
