# Offline Zalo mock

An offline mock of the Zalo web backend that the **real** personal-account
gateway in `server/src/gateway/zca.ts` (built on `@zalos/zalo-sdk`) talks to
end to end. It exists so
the whole zalos stack (Noise tunnel, account manager, persistence, RPC
surface) can be exercised without a real Zalo account.

Honest scope note: the request/response shapes here were first built
from `zca-js`'s parsing code (zalos's former Zalo client) plus observed
QR-login behavior, and are now kept in line with `@zalos/zalo-sdk`
(`packages/zalo-sdk/src`). The mock proves the zalos <-> SDK integration
and adapter behavior; it does **not** prove anything about
real Zalo server behavior.

## Layout

- `compose.yaml` - WireMock plus the gateway, one network. The gateway
  is published on `127.0.0.1:7355` only.
- `wiremock/mappings/` - plaintext JSON stub mappings; this is the part
  humans edit. Bodies are wrapped as `{"data": {<zalo response>}}`; the
  outer `data` object is what the gateway encrypts back to the client.
  Stateful flows (the QR login state machine) use WireMock Scenarios.
  Response templating is opt-in: a stub that uses Handlebars (`{{...}}`)
  must list `"transformers": ["response-template"]`, so `bodyFileName`
  binaries are served byte-exact.
- `wiremock/__files/` - binary fixtures: the QR PNG (also inlined in
  `20-qr-flow.json` and used as an upload source by the e2e suite),
  sample media, per-uid solid-colour avatars (`avatars/`, served by
  `55-avatars.json` with a grey fallback), sticker PNGs with
  transparency (`stickers/`) and the gif thumbnail.
- `gateway/` - a small Bun service that does the two things WireMock
  cannot:
  - **crypto**: Zalo's application-layer encryption. Login endpoints
    (`/api/login/*`) use the zcid/zcid_ext key derivation; everything
    else uses the session key from `zpw_enk` (`MOCK_SESSION_KEY`,
    AES-128-CBC zero-IV, as in `packages/zalo-sdk/src/core/crypto.ts`). Encrypted `params` are decrypted
    and forwarded to WireMock as a JSON body (or the
    `x-zalo-decrypted-params` header for multipart/GET), and scalar
    fields are also mirrored as `mock_<name>` query params so stubs can
    template on them (see `sticker_detail`). Response `data` is
    re-encrypted. Unencrypted endpoints pass through.
  - **WebSocket**: serves the url advertised in `zpw_ws`, derived from
    the `Host` header of the login request (`ws://127.0.0.1:7355` from
    the host, `ws://gateway:7355` from a container on the compose
    network; `MOCK_WS_BASE` overrides it), sends the cipher-key frame, answers old-message
    requests (cmd 510/511/610/611) from its in-memory store, and pushes
    events driven by the control API.

## Running it

```sh
docker compose -f mock/compose.yaml up -d --build
# gateway: http://127.0.0.1:7355  wiremock admin inside the network
```

Run zalos against it (dev mode on the host):

```sh
cd server
ZALOS_ZALO_MOCK_URL=http://127.0.0.1:7355 bun run src/cli.ts serve --dev
```

Or fully containerized (see `deploy/docker/compose.mock.yaml`); the
same mock stack serves both, no environment needed:

```sh
docker compose -f mock/compose.yaml up -d
docker compose -f deploy/docker/compose.mock.yaml up -d --build
```

The mock models a single Zalo account (uid `777000111`): a new listener
socket kicks every other one with close code 3000, as real Zalo does for
a second web session. Do not keep a host zalos and the containerized one
logged in at the same time (or run the e2e suite while the container's
account is online); they displace each other.

`ZALOS_ZALO_MOCK_URL` is refused outside `--dev`/`--local`.

## Control API (`/__mock/*`)

All endpoints take and return JSON.

### QR flow (drives the WireMock `zalo-qr` scenario)

```sh
curl -X POST localhost:7355/__mock/qr/scan     # code scanned on phone
curl -X POST localhost:7355/__mock/qr/confirm  # login confirmed
curl -X POST localhost:7355/__mock/qr/decline  # login declined
curl -X POST localhost:7355/__mock/qr/expire   # code expired
```

### Event injection

```sh
# incoming user or group message
curl -X POST localhost:7355/__mock/events/message \
  -H 'content-type: application/json' \
  -d '{"type":"user","uidFrom":"777000222","idTo":"777000111",
       "dName":"Trần Thị Hoa","content":"Tối nay ăn gì?"}'

curl -X POST localhost:7355/__mock/events/reaction -d '{"msgId":"...","icon":"heart","uidFrom":"777000222"}'
curl -X POST localhost:7355/__mock/events/undo -d '{"type":"user","msgId":"..."}'
curl -X POST localhost:7355/__mock/events/typing -d '{"threadId":"777000222"}'
curl -X POST localhost:7355/__mock/events/seen -d '{"threadId":"777000222","msgId":"..."}'
curl -X POST localhost:7355/__mock/events/delivered -d '{"threadId":"777000222","msgId":"..."}'
curl -X POST localhost:7355/__mock/events/group -d '{"act":"update","data":{...}}'
curl -X POST localhost:7355/__mock/events/friend -d '{"act":"req_v2","data":{...}}'
```

### History and misc

```sh
curl -X POST localhost:7355/__mock/old-messages/user  -d '{"msgs":[{...}]}'
curl -X POST localhost:7355/__mock/old-messages/group -d '{"msgs":[{...}]}'
curl -X POST localhost:7355/__mock/ws/kick -d '{"reason":3000}'   # or "abnormal"
curl -X POST localhost:7355/__mock/cookie/rotate -d '{"name":"zpw_sek","value":"v2"}'
                                    # Set-Cookie on every proxied response
curl -X POST localhost:7355/__mock/reset                          # journal + scenarios + stores + cookie rotation
curl      localhost:7355/__journal                                # plaintext request journal
curl      localhost:7355/__mock/state                             # live ws socket count
```

The journal is WireMock's request journal: every request the SDK sent
to "Zalo", with decrypted params either as the JSON body or the
`x-zalo-decrypted-params` header - exactly what a test can assert on.

## Negative stubs

`40-messaging.json` matches magic values in the `message` field:

- `__session__*` -> `error_code 216` (session expired)
- `__ratelimit__*` -> `error_code 2215` (rate limited)
- `__error__*` -> `error_code -1` (generic error)

## Adding a stub

1. Find the request shape in `packages/zalo-sdk/src/apis/<module>.ts` (and,
   for anything new, confirm it against a real capture).
2. Add a mapping under `wiremock/mappings/` with the path
   `/<original-host>/<path>`; match `urlPath` or `urlPathPattern`.
3. Wrap the response as `{"data": {<inner>}}`. Use
   `{{randomValue ...}}` for ids and `{{request.query.mock_<name>}}` to
   echo decrypted params.
4. `docker restart mock-wiremock-1` reloads the mappings.

## E2E suite

`cd server && bun run test:e2e` brings the stack up (skips cleanly when
Docker is unavailable), starts a real zalos `--dev` server with the
seam, and drives the whole flow: QR login incl. declined/expired,
history ingest, send/receive of every message kind, reactions, recall,
seen/delivered/typing both directions, second-device convergence,
restart resume, ws kick + reconnect, session expiry, rate limits and
sealed `media.fetch`. `regressions.test.ts` adds: exactly one event and
one row per incoming message across kicks, restarts and re-logins,
thread names, group deputies, group history on demand, full-size
avatars and rotated-cookie persistence.
