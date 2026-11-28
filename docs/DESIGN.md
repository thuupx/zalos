# zalos design

zalos lets one Zalo account be used from many devices, and many Zalo accounts
from one device, through a self-hosted proxy. Every user runs their own server;
nothing is centralized.

```
Flutter client (iOS/Android/Windows/macOS/Linux/web)
   |  WebSocket over the tailnet, one Noise session per channel
zalos-server (Bun, Linux)   -- @zalos/zalo-sdk -->  Zalo (as a Zalo Web session)
```

## Components

| Path | What |
|------|------|
| `crates/zalos-noise` | Rust wrapper over the `snow` Noise implementation. The only place Noise runs. Built as wasm (Bun server, web client) and as a native lib through flutter_rust_bridge (other clients). |
| `crates/zalos-vault` | Rust HPKE (RFC 9180) vault used for encryption at rest. Built as wasm (server) and native/wasm (client) like the Noise crate. |
| `packages/zalo-sdk` | `@zalos/zalo-sdk`, our own TypeScript client for the Zalo Web/PC protocol (HTTP APIs, QR login, realtime listener, call signalling). See [ZALO_SDK_AND_CALLS.md](ZALO_SDK_AND_CALLS.md). |
| `server/` | Bun, TypeScript, `@zalos/zalo-sdk`, `ws`, built-in `bun:sqlite`. |
| `client/` | Flutter app `zalos`. |

No cryptographic protocol code is written by hand in TypeScript or Dart. Both
sides call the same `zalos-noise` crate.

## Constraints of the Zalo Web protocol

- It is a Zalo Web session. Zalo allows one web listener per account, so opening
  Zalo Web / Zalo PC web mode for that account stops the server listener. The
  server reconnects with backoff and reports account status.
- Zalo Web has no "recent conversations" API and limited history, so the server
  is the system of record: it persists every message and event it sees in SQLite.
- To Zalo, each account is a regular Zalo Web session, the same as chat.zalo.me
  in a browser. The server keeps request rates human-like and never fans a
  client action out into multiple Zalo calls.
- Calls use Zalo's proprietary ZRTC signalling, not standard WebRTC. The server
  speaks ZRTC to Zalo through `@zalos/zalo-sdk` and bridges media to clients over
  WebRTC (`server/src/accounts/call_*`, `zrtc_*`). See
  [ZALO_SDK_AND_CALLS.md](ZALO_SDK_AND_CALLS.md).

## Channels and Noise

Every WebSocket carries exactly one Noise session. Channel kinds:

| Kind | URL | Prologue |
|------|-----|----------|
| pair | `/v1/pair/<pairingId>` | `zalos/1/pair/<pairingId>` |
| control | `/v1/control` | `zalos/1/control` |
| account | `/v1/account/<slot>` | `zalos/1/account/<slot>` |

`<slot>` is a random server-assigned id, not the Zalo uid. The URL is cleartext
routing only; the prologue binds it into the handshake, so a mismatched or
tampered channel fails the handshake.

Suite: `Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s` for all channels. The client is
always the initiator and always knows the server static key before connecting.

- **pair**: psk is a one-time 32-byte pairing secret (10 minute expiry, single
  use) shown by the server as a QR / `zalos://pair?...` string together with the
  server address and server static public key. The server learns the device
  static public key, stores the device, and returns a random per-device psk
  inside the encrypted session.
- **control / account**: psk is the per-device psk. The server looks the device
  up by the static key revealed in handshake message 1, rejects unknown or
  revoked devices, and for account channels checks the device x account ACL.

A private tunnel per account therefore means: separate socket, separate
handshake, separate transport keys, separate authorization. Revoking a device
deletes its public key and psk.

The first paired device is `admin`. Admin devices can pair further devices,
revoke devices, edit ACLs, and start a Zalo QR login from the client.

## Framing

One WebSocket binary message is one Noise transport message (max 65535 bytes).
Plaintext frame:

```
type:u8 | flags:u8 | stream:u32be | chunk (<= 60000 bytes)
type  1 = JSON message, 2 = blob data
flags bit0 = FIN (last chunk of this stream id)
```

JSON messages:

```
request   {"id": n, "method": "...", "params": {...}}
response  {"id": n, "result": ...} | {"id": n, "error": {"code": "...", "message": "..."}}
event     {"event": "...", "seq": n, "data": {...}}
```

Blobs (uploads and downloads) are referenced from JSON by stream id.

Limits per channel: at most 8 concurrently open inbound streams, frames are
capped by the Noise transport message size, per-device and global connection/upload
quotas plus a token-bucket RPC rate limiter protect server resources, and a
channel whose outgoing buffer exceeds 8 MiB is closed so a stalled client cannot
grow server memory. Outbound traffic toward Zalo is paced through a 300 ms send
queue per account (`CallQueue` in `server/src/gateway/zca.ts`: one call at a
time, at least 300 ms apart).

Close codes:

| code | meaning |
| --- | --- |
| 4001 | unauthorized: bad or revoked credentials; also used for every pre-authentication rejection so slot existence is not revealed |
| 4002 | protocol error after authentication: bad framing, oversized message, too many streams; recoverable, reconnect with backoff |
| 4004 | the account slot (or pairing id) is gone; only sent after authentication |
| 1013 | the server is shedding backpressure; reconnect and resync |

Sockets that send no handshake message 1 within 10 seconds are dropped, and
plain HTTP requests to tunnel paths get a 404.

Media downloads validate the URL before fetching: the literal host and every
resolved address are parsed (mapped, compatible, 6to4 and NAT64 IPv6 forms
are folded to their embedded IPv4), only global-unicast addresses pass, and the
HTTP client pins the validated IP directly at connect time (preventing DNS
rebinding TOCTOU) while refusing HTTPS-to-HTTP redirects. A 20 second
connect/headers timeout and a 120 second overall timeout apply.

## Multi-device sync

Each account has an append-only event log with a monotonically increasing
`seq`, issued from a persistent per-slot counter so pruning the log or
restarting the server never reissues a `seq` a client already saw (a
reissued `seq` would make connected clients silently drop the new events).
Every state change (incoming message, message sent from any device,
reaction, recall, seen) is appended and broadcast to all
connected devices of that account. On connect a client calls `sync` with its
last seen `seq` and receives the gap. A message sent from device A reaches
device B as a normal event, and is also what Zalo echoes to the phone app.

## API (milestone 1)

### Pair channel

- `pair.complete {deviceName, boxPublicKey}` -> `{deviceId, psk, role, server:{name, version, fingerprint}}`.
  `boxPublicKey` is required: base64, exactly 32 bytes (the device's vault box
  key; the client keeps the private half).

### Control channel

- `manifest.get` -> `{server:{name,version,fingerprint}, device:{id,name,role}, accounts:[{slot,uid,displayName,avatarUrl,status,unread,vaultKey}]}`
  where `uid` is the account's own Zalo uid and `vaultKey` is the account's
  vault public key (base64) or `null`.
- `manifest.changed` event.
- `devices.list` (admin) -> `{devices:[{id,name,publicKey,boxPublicKey,boxFingerprint,role,createdAt,lastSeenAt,slots}]}`
- `devices.revoke {deviceId}` (admin). Clears any pending vault request and
  stored wrapped blob of the device and closes its channels.
- `devices.setAcl {deviceId, slots}` (admin).
- `pairing.create {role}` (admin) -> `{pairingId, secret, expiresAt, uri}`.
  The uri advertises the address the server actually listens on.
- `accounts.loginQr.start` (admin), events `loginQr.image` (blob stream),
  `loginQr.scanned`, `loginQr.done {slot}`, `loginQr.failed {reason}` - sent
  strictly in order.
- `accounts.remove {slot}` (admin).

### Vault (control channel)

- `vault.setKey {slot, publicKey}` (admin) -> `{ok, fingerprint}`. Requires
  admin role and ACL on the slot. First set transitions `vault_state`
  (`unsealed -> migrating -> sealed`), seals every stored plaintext record of
  the slot (messages, event log entries, media cache), and vacuums with
  `PRAGMA secure_delete=ON`. Re-setting the same key is a no-op; a different
  key answers `conflict`.
- `vault.claim {}` -> `{claimed}`. Atomic compare-and-set: `true` only for
  the first device that ever calls it on this server (the one expected to
  generate the vault root), `false` for everyone after.
- `vault.request {}` -> `{ok}`. Marks the device as needing the root and emits
  `vault.requested {deviceId, name, boxPublicKey, fingerprint}` on the control
  channels of all admin devices.
- `vault.requests.list {}` (admin) -> `{requests:[{deviceId, name, boxPublicKey, fingerprint, requestedAt}]}`
- `vault.grant {deviceId, wrapped}` (admin) -> `{ok}`. `wrapped` is an opaque
  base64 blob (the root wrapped to the device's box key by an existing device).
  Stored until fetched; emits `vault.granted` on that device's control
  channels.
- `vault.fetch {}` -> `{wrapped}` or `null`. Deletes the blob once returned.

### Account channel

- `sync {sinceSeq}` -> `{events:[{event, seq, data}], latestSeq, reset, more}`.
  At most 500 events per call; clients loop while `more` is true. `reset`
  means the event log no longer reaches `sinceSeq`; reload everything.
- `threads.list {}` -> `{threads:[Thread]}`: all threads (cap 2000), ordered
  pinned desc then `lastTs` desc. No paging.
- `messages.list {threadId, threadType, limit?, before?}` ->
  `{messages:[MessageRecord], hasMore}`. `before` is `{ts, id}`; only records
  strictly older in `(ts, id)` order are returned, newest first.
- `messages.sendText {threadId, threadType, cliId, text, quote?, mentions?}`.
  `quote` is `{raw}` - the decrypted `raw` object from the quoted message's
  body, passed back to the server.
- `messages.sendMedia` (image, video, file, voice), `messages.sendSticker`,
  `stickers.search`, `messages.react {msgId, threadId, threadType, icon}`
  (empty `icon` removes the caller's reaction), `messages.recall`,
  `messages.delete`, `threads.markSeen {threadId, threadType}` (persists
  `unread=0` and emits a sequenced `thread.updated`), `threads.typing`,
  `contacts.list`, `groups.list`, `groups.info`, `users.info`.
- `media.fetch {url}` -> `{stream, size, contentType, sealed}`. `size` is the
  plaintext size; when `sealed` the blob is the stored encrypted file
  (`header(32) || sealed chunks`), which the client opens with
  `FileOpener::with_root` under aad
  `zalos/1/media/<slot>/<sha256(url) hex>/<size>`.
- `threads.setPinned {threadId, threadType, pinned}` and
  `threads.setMuted {threadId, threadType, muted}` apply on Zalo
  (`setPinnedConversations`, `setMute` with mute-forever semantics), persist
  the flag and emit a sequenced `thread.updated`. On every connect the
  account manager pulls `getPinConversations` and `getMute` so local threads
  converge to Zalo's truth.
- `threads.markUnread {threadId, threadType}` calls `addUnreadMark`, sets
  `unread >= 1` and a `marked_unread` flag; `threads.markSeen` clears the
  flag through `removeUnreadMark`.
- `threads.delete {threadId, threadType}` calls `deleteChat` with the stored
  last-message reference, then removes the thread, its messages, their
  event-log content and media cache entries, and emits `thread.deleted`.
- `messages.forward {msgId, threadId, threadType, to[], raw}` forwards via
  `forwardMessage` to at most 20 destinations. `raw` is the plaintext the
  client supplies, since sealed message content is unreadable server side.
- `users.info {uids}` batches `getUserInfo` behind a 24 h `profiles` cache;
  unknown ids return an empty `displayName`. `groups.info` additionally
  returns `members` as `{uid, displayName, avatarUrl, role}` resolved through
  `getGroupMembersInfo`, and caches member profiles for `users.info`.
- `accounts.logout {slot}` calls the Zalo logout, wipes the stored
  credentials and leaves the row as `needs_login`.
- Typing events carry `displayName` when the profiles cache knows the sender.
  `friendEvent` broadcasts `contacts.changed`; group update events apply
  rename/avatar changes and emit `thread.updated`.`

### Message record

Identical everywhere: RPC results, events, `Thread.lastMessage` and the event
log. Clear fields:

    id, cliId, threadId, threadType, senderId, ts, isSelf, kind, recalled,
    delivery?,
    reactions: {<icon>: [<uid>, ...]}
  `delivery` is folded from seen/delivered receipts onto own messages and is
  monotonic (`sent` -> `delivered` -> `seen`); group records also keep
  `seenBy`. Each fold emits `message.updated`.

then exactly one of:

- `sealed`: base64 HPKE record over the UTF-8 JSON of the body. aad =
  `zalos/1/msg/<slot>/<msgId>`.
- `body`: the body object in plaintext, only while the account has no vault
  key: `{senderName, text?, attachments?, sticker?, quote?, mentions?, raw?}`.

A recalled record keeps only the clear fields with `recalled: true`.

Events: `message.new`, `message.updated` (own-send media merge, reactions,
recall), `message.deleted`, `thread.updated`, `threads.reset` (history
ingested, reload `threads.list`), `manifest.changed`, plus the vault and
loginQr events above.

`media.fetch` proxies Zalo CDN downloads through the server and caches them
per account slot, so clients never talk to Zalo directly.

Upload temp files are plaintext on disk for the duration of a send because
the gateway hands `@zalos/zalo-sdk` a file path to upload from; they live under
`tmp/` inside the data directory,
are deleted when the send finishes, and the whole `tmp/` directory is wiped
at startup. Download temp files also land in `tmp/` and are removed after
sealing.

`cliId` makes sends idempotent: the first send stores the result under the
caller-supplied id, and repeating the same call returns the stored result
without touching the gateway again.

## Server security validation

`zalos-server doctor` runs during install and at every start. Critical failures
stop the server.

- Tailscale is installed, running and logged in.
- The listen address is the Tailscale address (100.64.0.0/10 or the tailnet
  IPv6 range), never `0.0.0.0`, and the port is not exposed by Tailscale Funnel.
- The process is not root and runs as a dedicated user.
- Data directory is `0700`, key and database files are `0600`.
- systemd unit uses sandboxing (`NoNewPrivileges`, `ProtectSystem=strict`,
  `PrivateTmp`, `ProtectHome`, `PrivateDevices`,
  `RestrictAddressFamilies`).
- The service user has no login shell (warning only).
- Bun version and clock sync are acceptable.
- Prints the server key fingerprint for out-of-band comparison when pairing.

Any critical failure exits non-zero. The Tailscale CLI used by the doctor
and by serve/pair is configurable through `ZALOS_TAILSCALE_BIN` and
`ZALOS_TAILSCALE_SOCKET` (the installer forwards them to the doctor), which
matters for container deployments where Tailscale runs in a sidecar.

`--dev` binds to localhost and skips the Tailscale checks. It is for
development only and is refused when a systemd unit is detected.

`--local` is the container development mode used by
`deploy/docker/compose.local.yaml`. It is accepted only when both
`ZALOS_CONTAINER=1` and `ZALOS_ALLOW_LOCAL=1` are set. In this mode the
server binds `0.0.0.0` so a host-published port can reach it, the doctor
skips the Tailscale checks (and emits a warning instead) while keeping
every other critical check, and pairing uris use `ZALOS_PUBLIC_HOST` /
`ZALOS_PUBLIC_PORT` (default `127.0.0.1` and the listen port). This mode
has no network-level protection beyond the host publishing the port on
loopback only; it is a development convenience, not a deployment option.

## Client

Flutter, Riverpod. Device static key and per-device psk live in platform secure
storage (the data-protection keychain in release builds, the legacy keychain
in debug). On web, `flutter_secure_storage` requires a secure context, so the
web client must be served over HTTPS (for example via Tailscale Serve); it
keeps its wrapping key in `localStorage`, which makes web the weakest
platform for key storage. Layout adapts across mobile (bottom tabs) and wide
screens (three-pane layout) with an account switcher and cohesive design tokens.

## Vault: encryption at rest with client-held keys

Goal: a stolen disk, backup, snapshot or database file, and any compromise of
the server after the fact, must not reveal stored history. Non-goal: hiding
live traffic from someone with root on a running server. The server holds the
Zalo session and sees each message in the clear at the moment it passes
through; no design can change that. Zalo session credentials stay usable by the
server so it can restart unattended.

Mechanism: HPKE (RFC 9180, X25519-HKDF-SHA256, HKDF-SHA256, ChaCha20-Poly1305)
through the `hpke` Rust crate in `crates/zalos-vault`, built for the server
(wasm) and the client (flutter_rust_bridge) like the Noise crate. Bulk data is
encrypted with a symmetric key; only that key is wrapped asymmetrically.

- **Vault root**: 32 random bytes generated by the first device. It never
  reaches the server and never travels inside a Noise tunnel in the clear,
  because the tunnel terminates at the server.
- **Per-account key pair**: derived from the root and the account slot. Devices
  upload only the public key (`vault.setKey`). The server seals with it and
  cannot open what it sealed.
- **Sealed at ingest**: message body (text, attachments, quote, sender name,
  raw payload), the matching event log entries, cached media and upload temp
  files. Media is sealed in 1 MiB chunks with one HPKE context per file.
- **Left in the clear** so the server can order, sync and act: thread and
  message ids, timestamps, kind, sender id, unread counters, thread names and
  avatars, and the minimal Zalo message reference needed for react, recall,
  delete and read receipts.
- **On the wire** the server forwards sealed records as stored; clients open
  them. A client that wants to quote a message sends the quoted content back,
  since the server no longer has it.
- An account that has no vault key yet (created from the server CLI before any
  device connected) stores plaintext until a device uploads the key, then the
  server seals the existing rows and vacuums.

Giving the root to another device:

1. **QR from an existing device** (preferred): the pairing QR is rendered by the
   existing device, which appends the root to the pairing uri locally. The root
   goes screen to camera and never touches the server.
2. **Approval**: a device paired from the server CLI registers a box public key
   and waits. An existing device shows the new device's key fingerprint, the
   user compares it with the one on the new device and confirms, and the
   existing device wraps the root to that key with HPKE. The server relays the
   ciphertext only. The confirmation step is what stops a compromised server
   from registering its own key and asking for the root.

Losing every device that holds the root makes stored history unreadable. The
client offers an export of the root as a recovery code (gated behind device
biometric/passcode step-up authentication with conditional 60-second clipboard
cleanup).

### Revocation, key rotation, and physical erasure limits

- **Transport revocation vs. cryptographic rotation**: revoking a device wipes
  its Noise credentials and blocks all further server access, but a previously
  copied vault root can still decrypt ciphertexts obtained earlier. To rotate
  cryptographic access for future messages, an admin invokes `vault.rotate`
  with an incremented key generation (`kv`) derived via HKDF domain separation
  (`zalos/vault/2/<slot>/kv/<kv>`).
- **Memory zeroization**: long-lived private keys and HKDF intermediate keying
  material inside the Rust crates (`zalos-vault`, `zalos-noise`) are explicitly
  zeroized on drop via `zeroize`. Managed runtimes (Dart, JavaScript, WASM)
  and OS clipboards cannot guarantee deterministic memory erasure.
- **Physical erasure**: SQLite `PRAGMA secure_delete = ON`, WAL checkpointing,
  `VACUUM`, and `media_refs`-driven cache unlinking remove deleted data from
  live files, but cannot guarantee physical erasure from SSD wear-leveling
  blocks, copy-on-write snapshots, volume backups, or remote Zalo servers.
