# zalos developer onboarding (English)

> Tiếng Việt: [../vi/README.md](../vi/README.md)

Welcome to zalos. This guide takes you from a fresh clone to shipping a change
safely. Read it in order the first time; afterwards use it as a reference.

## What zalos is

zalos lets **one Zalo account be used from many devices**, and **many Zalo
accounts (personal and Official Accounts) from one app**, through a server that
each user hosts themselves. Nothing is centralized.

```
Flutter client (iOS, Android, macOS, Windows, Linux, Web)
   |  WebSocket, one Noise IKpsk2 session per channel
zalos server (Bun + TypeScript + SQLite)
   |  @zalos/zalo-sdk (Zalo Web protocol) / OA OpenAPI
Zalo
```

The server is the system of record: it keeps one Zalo Web session per account,
persists every message and event in SQLite, and fans state out to every paired
device. Clients hold the vault keys that encrypt message bodies at rest.

## Reading order

| # | Guide | You will learn |
|---|-------|----------------|
| 1 | [Setup](01-setup.md) | Toolchains, clone, first build and test run on every layer |
| 2 | [Architecture](02-architecture.md) | Components, channels, framing, sync, vault, gateways, SDK |
| 3 | [Development workflow](03-development.md) | Running server + client locally, fake/mock Zalo, recipes for common changes |
| 4 | [Testing and CI](04-testing-and-ci.md) | Test suites, what CI enforces, how to verify a change |
| 5 | [Deployment](05-deployment.md) | Docker + Tailscale, local mode, NAS, HTTPS for the web client, upgrades |
| 6 | [Conventions](06-conventions.md) | Code style, commits, security rules, Zalo account safety |
| 7 | [Troubleshooting](07-troubleshooting.md) | Known failures and how they were fixed |

Deep references (read when you touch the area):

- [docs/DESIGN.md](../../DESIGN.md): wire protocol, RPC surface, vault design.
- [docs/SECURITY_ARCHITECT.md](../../SECURITY_ARCHITECT.md): threat model and controls.
- [docs/ZALO_SDK_MIGRATION_AND_CALLS.md](../../ZALO_SDK_MIGRATION_AND_CALLS.md):
  the internal Zalo SDK and the voice/video call stack.

## Repository map

| Path | What lives there |
|------|------------------|
| `crates/zalos-noise` | Rust Noise wrapper (`snow`). The only place Noise runs. |
| `crates/zalos-vault` | Rust HPKE (RFC 9180) vault, key derivation, `zeroize`. |
| `crates/*-wasm` | wasm-bindgen wrappers of the two crates for the Bun server. |
| `server/` | Bun + TypeScript server: tunnel, RPC methods, account manager, store, CLI. |
| `server/vendor/` | Committed wasm builds of the crates (rebuilt by `scripts/build-*-wasm.sh`). |
| `packages/zalo-sdk` | `@zalos/zalo-sdk`, our own Zalo Web protocol client (replaced `zca-js`). |
| `client/` | Flutter app. Rust FFI crate in `client/rust`, bindings in `lib/src/rust_lib`. |
| `mock/` | Offline Zalo backend (WireMock + Bun gateway) for end-to-end tests. |
| `deploy/` | Hardened Docker images and compose files, systemd unit, installer. |
| `scripts/` | Build helpers for wasm, web client, icons. |
| `landing/` | Marketing site (Next.js + shadcn, deployed to Vercel). |
| `.claude/skills/` | Agent skills that help with onboarding and common tasks. |

## Glossary

| Term | Meaning |
|------|---------|
| **slot** | Random server-side id of a Zalo account. Never the Zalo uid. |
| **channel** | One WebSocket carrying one Noise session: `pair`, `control` or `account/<slot>`. |
| **pairing** | One-time, 10-minute code (`zalos://pair?d=...`) that enrolls a device. |
| **admin / member** | Device roles. Admins pair and revoke devices, edit ACLs, log in Zalo accounts. |
| **ACL** | Which account slots a device may open. Empty by default for new members. |
| **seq** | Monotonic per-account event counter used for multi-device sync. |
| **vault** | Client-held HPKE keys that seal message bodies and cached media at rest. |
| **gateway** | Server adapter to Zalo: `zca.ts` (personal, via the SDK), `oa.ts` (Official Account), `fake.ts`/`mock.ts` (tests). |
| **tailnet** | The private Tailscale network the server is meant to live on. |

## Getting help from an agent

This repo ships Claude Code skills under `.claude/skills/`:

- `zalos-onboarding`: answers "how do I ..." questions about this repo, walks a
  new developer through setup, and points to the right file.
- `zalos-dev-tasks`: step-by-step playbooks for common changes (new RPC
  method, new UI string, Rust API change, SDK endpoint) and the checks to run.

Open the repo in Claude Code and ask, for example, "help me set up zalos for
development" or "add an RPC method that returns the thread's pinned topics".
