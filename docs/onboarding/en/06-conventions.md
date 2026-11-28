# 6. Conventions

> Tiếng Việt: [../vi/06-conventions.md](../vi/06-conventions.md) · Back to [index](README.md)

## 6.1 Language

- **Code, comments, commit messages, docs in the repo: English.** The onboarding
  guide is the exception and ships in both English and Vietnamese; keep the two
  in sync when you edit one.
- **UI strings: Vietnamese first**, English second, both through the l10n tables.

## 6.2 Commits and branches

- Conventional Commits style subject, imperative, lower case, no trailing period:
  `fix: keep Zalo session cookies through QR login`,
  `feat: add mention jump navigation`, `chore: bump client build to 16`,
  `docs: add bilingual onboarding guide`.
- Types in use: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `ci`.
- Body: what was broken or missing, the root cause, and what the change does.
  Wrap at ~72 columns.
- One logical change per commit. Do not mix formatting churn with behavior.
- Branch from `main` (`feat/<topic>`, `fix/<topic>`), open a PR, keep CI green.

## 6.3 Code style

**TypeScript (server, SDK, landing)**

- Strict TypeScript; `bunx tsc --noEmit` must be clean. No `any` without a
  comment explaining why.
- Validate every RPC param at the boundary (`String(...)`, enum checks, size
  limits). Never trust client input, even from paired devices.
- Prefer small pure functions; keep Zalo calls in gateways/SDK, persistence in
  `store/`, orchestration in `accounts/manager.ts`.
- Comments explain **why** (protocol quirks, security reasoning), not what.

**Dart (client)**

- `flutter analyze` clean (`analysis_options.yaml`).
- UI depends on `domain/services.dart` interfaces, not on data classes directly.
- Colors from `ZalosTokens`, text from `S.t()`, icons from `z_icons.dart`.
- Never edit generated bindings in `lib/src/rust_lib/`; regenerate them.

**Rust**

- All crypto lives here. Zeroize secrets (`zeroize`), no `unwrap()` on input
  data, tests for every API.

## 6.4 Zalo account safety

zalos uses Zalo's unofficial web protocol. Zalo can restrict or lock accounts
that behave like bots. Rules:

- **Develop against the fake gateway or the mock.** Touch real Zalo only for
  final verification, with your own account, and as few times as possible.
- **Never increase request volume.** One user action = at most one Zalo call.
  Keep the 300 ms per-account send queue. No polling loops against Zalo, no
  bulk scraping, no retries without backoff.
- **Mimic the official web client exactly** (endpoints, headers such as
  `Origin`/`Referer`, parameters). If Zalo rejects a request, find out what the
  real client sends; do not brute-force variations against production.
- **QR login** is a normal user action, but repeated failed logins are noisy:
  diagnose from logs (`login QR failed: ...`) before asking someone to scan again.
- Opening Zalo Web/PC web mode elsewhere displaces the server session; the
  server backs off (`ZALOS_ZCA_DISPLACED_MS`) instead of fighting for it.

## 6.5 Security rules

- Never commit secrets: `.env`, `server/data*/`, cookies, Zalo credentials,
  pairing URIs, captures from `.research/`, private keys. Gitleaks runs in CI.
- Pairing URIs and login QRs are secrets while valid. Do not paste them in
  issues, PRs or chat logs that others can read.
- Do not weaken `doctor` checks, container hardening (`read_only`, `cap_drop:
  ALL`, `no-new-privileges`, non-root uid 10001), CSP/COOP/COEP headers, the
  SSRF guard or role/ACL checks without a reviewed reason documented in the PR.
- Keep the server off the public internet. Use Tailscale (`tailscale serve` for
  HTTPS); never `tailscale funnel` or port-forward 7443.

## 6.6 Documentation

- Behavior or protocol change → update `docs/DESIGN.md`.
- Security control change → update `docs/SECURITY_ARCHITECT.md`.
- Setup, workflow or deploy change → update both onboarding languages.

Next: [7. Troubleshooting](07-troubleshooting.md).
