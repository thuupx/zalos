---
name: zalos-onboarding
description: Help a developer get started on the zalos repo (self-hosted multi-device Zalo proxy with a Bun server, Rust crypto crates and a Flutter client). Use when someone asks how to set up, build, run, test, deploy or understand zalos, where something lives, what a term means (slot, channel, pairing, vault, gateway), or says they are new to the project. Answers in the user's language (Vietnamese or English) using the bilingual guide in docs/onboarding.
---

# zalos onboarding

You are guiding a developer through the zalos codebase. The source of truth is
the bilingual guide; read the relevant page instead of answering from memory.

| Topic | English | Tiếng Việt |
|-------|---------|------------|
| Index, repo map, glossary | `docs/onboarding/en/README.md` | `docs/onboarding/vi/README.md` |
| Toolchains and first build | `docs/onboarding/en/01-setup.md` | `docs/onboarding/vi/01-setup.md` |
| Architecture | `docs/onboarding/en/02-architecture.md` | `docs/onboarding/vi/02-architecture.md` |
| Dev loop and recipes | `docs/onboarding/en/03-development.md` | `docs/onboarding/vi/03-development.md` |
| Tests and CI | `docs/onboarding/en/04-testing-and-ci.md` | `docs/onboarding/vi/04-testing-and-ci.md` |
| Deployment and env vars | `docs/onboarding/en/05-deployment.md` | `docs/onboarding/vi/05-deployment.md` |
| Conventions and account safety | `docs/onboarding/en/06-conventions.md` | `docs/onboarding/vi/06-conventions.md` |
| Troubleshooting | `docs/onboarding/en/07-troubleshooting.md` | `docs/onboarding/vi/07-troubleshooting.md` |

Deep references: `docs/DESIGN.md` (protocol, RPC list, vault),
`docs/SECURITY_ARCHITECT.md` (threat model), `docs/ZALO_SDK_AND_CALLS.md`
(SDK and calls).

## How to help

1. **Reply in the user's language.** Vietnamese question → Vietnamese answer and
   link the `vi/` page; English → `en/`.
2. **New developer ("help me get set up")**: walk through `01-setup.md` one layer
   at a time. Before suggesting installs, check what is already present:
   `bun --version`, `cargo --version`, `flutter --version`, `docker compose version`.
   Run the layer's checks for them and report pass/fail:
   - `cargo test -p zalos-noise -p zalos-vault`
   - `cd packages/zalo-sdk && bun install && bun test`
   - `cd server && bun install --frozen-lockfile && bunx tsc --noEmit && bun test`
   - `cd client && flutter pub get && flutter analyze && flutter test`
   Ask before installing toolchains system-wide.
3. **First run**: steer them to the fake gateway loop in `03-development.md` §3.2
   (`serve --dev --fake`, `pair --role admin`, `flutter run`), with
   `ZALOS_DATA_DIR=./data-dev`. Never start with real Zalo.
4. **"Where is X?" questions**: use the repo map and the server/client tables in
   `02-architecture.md`, then confirm with a grep before answering. Quote paths
   as `path:line`.
5. **Something broken**: check `07-troubleshooting.md` first; it covers the blank
   web page (CSP), HTTPS/cross-origin isolation, pairing errors, Zalo QR login
   errors (-4, `/jr/userinfo`), slow Docker builds and FRB binding drift.
6. **Making a change**: hand over to the `zalos-dev-tasks` skill for the
   step-by-step playbook.

## Guardrails

- Real Zalo accounts can be restricted. Do not run QR logins, `accounts add`, or
  anything that calls Zalo unless the user explicitly asks, and then do it once.
  Diagnose failures from logs before asking for another scan.
- Pairing URIs, login QRs, `.env`, `server/data*/`, cookies and `.research/` are
  secrets. Never paste them into commits, issues or shared logs.
- Never expose the server publicly; HTTPS goes through `tailscale serve`.
- If the guide and the code disagree, trust the code, tell the user, and offer to
  fix the guide in **both** languages.
