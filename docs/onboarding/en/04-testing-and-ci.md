# 4. Testing and CI

> Tiếng Việt: [../vi/04-testing-and-ci.md](../vi/04-testing-and-ci.md) · Back to [index](README.md)

## 4.1 Test suites

| Layer | Command | Notes |
|-------|---------|-------|
| Rust crypto | `cargo test -p zalos-noise -p zalos-vault` | Add vectors for every crypto change. |
| Zalo SDK | `cd packages/zalo-sdk && bun test` | Unit tests with mocked `fetch`/WebSocket. No network. |
| Server | `cd server && bunx tsc --noEmit && bun test` | ~390 tests, ~45 s. Uses the fake gateway; no network. |
| Server e2e | `cd server && bun run test:e2e` | Needs the offline mock running (`docker compose -f mock/compose.yaml up -d --build`). Skipped by plain `bun test`. |
| Client | `cd client && flutter analyze && flutter test` | Widget and data tests in `client/test/{data,ui,support}`. |
| Landing | `cd landing && bun run lint && bun run build` | Type and lint errors fail the build. |
| Container smoke | `deploy/docker/smoke.sh` | Smoke checks against a built image. |

Run a single server test file: `bun test test/pairing.test.ts`. Filter by name:
`bun test -t "pair"`.

Server test helpers are in `server/test/support/` (`client.ts` is a real Noise
client for end-to-end RPC tests, `helpers.ts` builds servers with the fake
gateway). Prefer them over ad-hoc setup.

## 4.2 What CI enforces

`.github/workflows/security.yml` runs on every push to `main` and every pull
request:

1. **Security test gate**: Rust tests (`--locked`), `bun install --frozen-lockfile`,
   `bunx tsc --noEmit`, and the security-critical server suites (security,
   security-architecture, security-phase2, pairing, vault-integ, zca-hardening,
   review-fixes, doctor, local-mode, upload-staging).
2. **Vulnerability and secret scanning**: OSV-Scanner over Bun, Rust and Flutter
   lockfiles, `cargo audit`, Gitleaks over the full history.
3. **SBOM**: CycloneDX SBOM plus SHA-256 checksums uploaded as artifacts.

CI does not run the full server suite or Flutter tests, so **run them locally**
before pushing.

## 4.3 Verifying a change

Pick the smallest check that proves it, then widen:

1. The unit test for the code you changed.
2. The full suite of the layer you touched.
3. For protocol, gateway or SDK changes: the e2e mock suite.
4. For UI changes: run the app and look at it, light and dark, narrow and wide.
5. For anything touching real Zalo: one careful real run on a deployed server,
   reading `docker logs` (QR login failures are logged as `login QR failed: ...`).

Write a test that **fails before your fix** for every bug you fix. If you cannot
reproduce it in a test, say so in the PR.

## 4.4 Security-sensitive areas

Changes here need tests in the security suites and an extra reviewer:

- `crates/*`, `server/src/tunnel/*`, `server/src/methods/pair.ts`,
  `server/src/methods/control.ts` (roles, ACL), `server/src/vault.ts`,
  `server/src/media.ts` (SSRF guard), `server/src/web_static.ts` (CSP/COOP/COEP),
  `server/src/doctor.ts`, `deploy/docker/*`.

Next: [5. Deployment](05-deployment.md).
