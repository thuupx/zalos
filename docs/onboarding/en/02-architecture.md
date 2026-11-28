# 2. Architecture

> Tiếng Việt: [../vi/02-architecture.md](../vi/02-architecture.md) · Back to [index](README.md)

This page is the mental model. The exact wire format and every RPC are in
[docs/DESIGN.md](../../DESIGN.md); read that before changing the protocol.

## 2.1 The big picture

```
 Devices (Flutter)                    Your server (Bun)                       Zalo
 ┌──────────────────┐   WebSocket   ┌─────────────────────────────┐
 │ iOS / Android    │  + Noise per  │ tunnel/   Noise + framing    │
 │ macOS / Windows  │◄────channel──►│ methods/  RPC handlers       │
 │ Linux / Web      │               │ accounts/ AccountManager     │──► Zalo Web protocol
 │                  │               │ gateway/  zca | oa | fake    │    (@zalos/zalo-sdk)
 │ vault keys live  │               │ store/    SQLite (WAL)       │──► OA OpenAPI
 │ here only        │               │ vault.ts  seal with pubkeys  │
 └──────────────────┘               └─────────────────────────────┘
```

Three ideas explain most of the code:

1. **The server is the system of record.** Zalo Web offers no "recent
   conversations" API and little history, so the server persists every message
   and event it sees and serves history from SQLite.
2. **One Zalo Web session per account, many devices.** The server holds the
   session; devices talk only to the server. A device action never fans out into
   several Zalo calls, and outbound Zalo traffic is paced (300 ms queue per
   account) to look human.
3. **Crypto only in Rust.** `crates/zalos-noise` (transport) and
   `crates/zalos-vault` (at rest) are compiled to wasm for the server/web and to a
   native library for the other clients. Nobody hand-writes crypto in TS or Dart.

## 2.2 Transport: channels and Noise

Every WebSocket carries exactly one Noise session
(`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`). The client is always the initiator
and pins the server static key it got at pairing.

| Channel | URL | psk | Used for |
|---------|-----|-----|----------|
| pair | `/v1/pair/<pairingId>` | one-time pairing secret | enrolling a new device |
| control | `/v1/control` | per-device psk | manifest, devices, pairing, Zalo login, vault |
| account | `/v1/account/<slot>` | per-device psk + ACL check | everything inside one Zalo account |

The URL path is cleartext routing; the Noise prologue binds it
(`zalos/1/<kind>/...`), so a tampered route fails the handshake. Close codes
`4001` (unauthorized), `4002` (protocol error), `4004` (slot gone), `1013`
(backpressure) tell the client whether to reconnect.

Framing inside Noise: `type:u8 | flags:u8 | stream:u32be | chunk`. Type 1 is
JSON (`request` / `response` / `event`), type 2 is blob data referenced by
stream id (uploads, downloads, QR images).

Code: `server/src/tunnel/` (server, framer, rpc) and
`client/lib/src/data/protocol/` (noise_channel, frame_codec, managed_channel).

## 2.3 Pairing and roles

1. An admin runs `zalos pair --role admin|member` (or uses **Devices** in the app)
   and gets `zalos://pair?d=<base64url>`: host, port, pairing id, secret, server
   public key. Single use, expires after 10 minutes.
2. The device opens the pair channel with that secret as psk, sends
   `pair.complete {deviceName, boxPublicKey}` and receives its per-device psk.
3. The first device is admin. Admins pair and revoke devices, set ACLs, start
   Zalo QR logins, and manage the vault. New members see no accounts until an
   admin grants them in the ACL.

When the page is served over HTTPS, the web client ignores the host in the
pairing URI and connects `wss://` to the page origin (`client/lib/src/data/protocol/ws_uri.dart`).

## 2.4 Server internals

| File | Role |
|------|------|
| `src/cli.ts` | CLI commands, startup modes (`--dev`, `--fake`, `--local`). |
| `src/server.ts` | Wires store, account manager, tunnel and method tables. |
| `src/tunnel/server.ts` | HTTP server: WebSocket upgrade routing, Noise sessions, static web client. |
| `src/web_static.ts` | Serves the Flutter web build with COOP/COEP/CSP headers. |
| `src/methods/pair.ts`, `control.ts`, `account.ts`, `account_extended.ts` | RPC method tables per channel kind. |
| `src/accounts/manager.ts` | `AccountManager`: one gateway per slot, event log, broadcast, send queue, reconnection, calls. |
| `src/gateway/types.ts` | `ZaloGateway` / `GatewayFactory` interfaces: the seam between zalos and Zalo. |
| `src/gateway/zca.ts`, `zca_extended.ts` | Personal-account gateway built on `@zalos/zalo-sdk`. |
| `src/gateway/oa.ts` | Zalo Official Account (OpenAPI) gateway. |
| `src/gateway/fake.ts`, `mock.ts` | In-memory fake for tests/dev, and the adapter for the offline mock. |
| `src/store/db.ts` | SQLite schema and queries (`bun:sqlite`, WAL, `secure_delete`). |
| `src/vault.ts` | Seals records with the account's vault public key. |
| `src/media.ts` | Media download/upload with the SSRF guard. |
| `src/security/audit.ts` | Structured, secret-redacting audit log. |
| `src/doctor.ts` | Hardening checks run before `serve` in container mode. |
| `src/accounts/call_*`, `zrtc_*` | Voice/video: Zalo ZRTC signalling and a WebRTC media gateway for clients. |

A typical account RPC flows like this:

```
client AccountSession._channel.request('messages.react', {...})
  -> tunnel/rpc.ts dispatch on the account channel
  -> methods/account.ts "messages.react"
  -> AccountManager.react(slot, ...)            (paced, persisted, broadcast)
  -> ZaloGateway.react(...) in gateway/zca.ts   (-> @zalos/zalo-sdk -> Zalo)
  -> event appended to the slot's log with a new seq, pushed to all devices
```

## 2.5 Multi-device sync

Each account has an append-only event log with a persistent, monotonically
increasing `seq` (never reissued, even after pruning or restart). Every state
change is appended and broadcast to all connected devices of that account. On
(re)connect a client calls `sync {sinceSeq}` and receives the gap, or `reset`
when it is too far behind.

## 2.6 Vault (encryption at rest)

- The first device generates a 32-byte **vault root** that never reaches the
  server.
- Per-account key pairs are derived from the root and the slot; devices upload
  only the **public** key (`vault.setKey`). The server seals message bodies,
  matching events, cached media and upload temp files with it and cannot open
  them.
- Metadata needed for ordering and actions (ids, timestamps, kind, sender,
  unread counters, thread names) stays in the clear.
- New devices get the root either from an existing device's QR (screen to
  camera) or by an admin approving a fingerprint-checked request.
- Losing every device with the root makes history unreadable; the app can export
  a recovery code behind biometric step-up.

Details and limits: [DESIGN.md "Vault"](../../DESIGN.md#vault-encryption-at-rest-with-client-held-keys)
and [SECURITY_ARCHITECT.md](../../SECURITY_ARCHITECT.md).

## 2.7 The Zalo SDK (`packages/zalo-sdk`)

Our own TypeScript implementation of the Zalo Web/PC protocol (it replaced
`zca-js`):

- `core/http.ts`: header profiles, cookie handling, AES envelopes, domain failover.
- `core/cookies.ts`: `ZaloCookieJar` (tough-cookie). Zalo sets session cookies
  for sibling hosts (for example `id.zalo.me` setting cookies for
  `chat.zalo.me`); the jar stores Zalo-domain cookies against their own Domain.
- `auth/login-qr.ts`: the `id.zalo.me` QR login flow. These endpoints require
  the login page as `Origin`/`Referer`.
- `ws/`: the realtime listener (framing, cipher key handshake, event commands).
- `apis/*`: domain modules (messaging, groups, board, friends, calls, ...).

Treat this package as protocol code: every change must be checked against real
behavior and must not increase request volume. See
[ZALO_SDK_MIGRATION_AND_CALLS.md](../../ZALO_SDK_MIGRATION_AND_CALLS.md).

## 2.8 Client internals

| Path | Role |
|------|------|
| `lib/main.dart` | App entry. |
| `lib/src/domain/models.dart`, `services.dart` | Domain models and the service interfaces the UI depends on. |
| `lib/src/data/` | Implementations: `server_link.dart` (control channel), `account_session.dart` (account channel, implements the services), `pairing.dart`, `vault.dart`, `key_store.dart` (secure storage), `media_cache.dart`. |
| `lib/src/data/protocol/` | WebSocket connect (io/web), Noise channel, frame codec, URI resolution. |
| `lib/src/noise/`, `lib/src/rust_lib/` | Dart side of the Rust FFI (generated bindings: do not edit by hand). |
| `rust/` | The FFI crate exposing Noise and vault to Dart via flutter_rust_bridge 2.12.0. |
| `lib/src/ui/state/` | Riverpod providers (`app_state.dart`, media, notifications, thread UI). |
| `lib/src/ui/theme/` | `tokens.dart` (all colors, light/dark), `theme.dart`, icons. |
| `lib/src/ui/l10n/` | Hand-rolled string tables: `strings_vi.dart` (primary) and `strings_en.dart`. |
| `lib/src/ui/<feature>/` | Screens: shell, threads, chat, contacts, groups, info, me, devices, pairing, vault, call, qr. |

State management is Riverpod 2.6. Layouts adapt between mobile (bottom tabs)
and wide screens (three panes).

Next: [3. Development workflow](03-development.md).
