# 5. Deployment

> Tiếng Việt: [../vi/05-deployment.md](../vi/05-deployment.md) · Back to [index](README.md)

zalos is meant to run **privately**, on your own machine, reachable only over a
Tailscale tailnet. Never expose port 7443 to the public internet.

## 5.1 Options at a glance

| Option | File | When |
|--------|------|------|
| Docker + Tailscale sidecar | `deploy/docker/compose.yaml` (+ `compose.sidecar-ro.yaml`) | Recommended. The container joins the tailnet itself, publishes no ports. |
| Local container mode | `deploy/docker/compose.local.yaml` | The host already runs Tailscale, or you only need loopback. |
| NAS / host-Tailscale variant | `deploy/docker/compose.nas.yaml` | Like local mode, bound to `127.0.0.1`, public host = the tailnet IP. |
| systemd on bare Linux | `deploy/install.sh` + `deploy/zalos.service` | No Docker. Installs Bun 1.4.4 and a `zalos` user. |

Every image builds the Rust wasm bundle and the Flutter web client, so the
**first build is slow** (tens of minutes on a small CPU). Later builds reuse the
cache.

## 5.2 Docker + Tailscale sidecar

```bash
cd deploy/docker
cp .env.example .env            # TS_AUTHKEY (optional), TS_HOSTNAME, TZ, ZALOS_PORT
docker compose up -d --build
docker compose logs -f tailscale   # approve the login URL if TS_AUTHKEY is empty
docker compose exec zalos zalos pair --role admin
```

To keep Tailscale's control socket out of the app container:

```bash
docker compose -f compose.yaml -f compose.sidecar-ro.yaml up -d
```

## 5.3 Local container mode

```bash
cd deploy/docker
ZALOS_BIND_HOST=127.0.0.1 ZALOS_PUBLIC_HOST=127.0.0.1 \
  docker compose -f compose.local.yaml up -d --build
docker compose -f compose.local.yaml exec zalos zalos pair --role admin
```

`ZALOS_PUBLIC_HOST` is the address written into pairing URIs. Set it to the
host's tailnet IP (`tailscale ip -4`) so other devices on the tailnet can pair.
Local mode runs `zalos doctor` first and refuses to start on critical failures.

## 5.4 HTTPS for the web client

The web client needs a secure context (SharedArrayBuffer and secure storage).
Plain `http://100.x.y.z:7443` on the tailnet is **not** enough. On the host:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7443
# web client: https://<machine>.<tailnet>.ts.net/
```

Over HTTPS the web client opens `wss://` to the page origin, so pairing URIs
that carry the tailnet IP still work. The server sends COOP/COEP/CSP headers from
`server/src/web_static.ts`; the CSP allows `'unsafe-eval'` (needed by
flutter_rust_bridge's wasm loader) and `fonts.gstatic.com` (Flutter font
fallback). CanvasKit is bundled locally (`--no-web-resources-cdn`).

## 5.5 Upgrading

```bash
git pull --ff-only
docker compose -f deploy/docker/<file>.yaml build      # slow on small machines; run under nohup
docker compose -f deploy/docker/<file>.yaml up -d
docker logs --tail 20 <container>                      # expect "zalos listening on ws://..."
```

Data lives in the `zalos-data` volume (`/var/lib/zalos`); rebuilding the image
keeps paired devices and Zalo sessions. Back up the volume before risky upgrades.

Checks after an upgrade:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<machine>.<tailnet>.ts.net/            # 200
curl -s --http1.1 -o /dev/null -w "%{http_code}\n" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://<machine>.<tailnet>.ts.net/v1/control                                        # 101
docker exec <container> zalos accounts list                                             # accounts online
```

The WebSocket check must use HTTP/1.1; over HTTP/2 the upgrade returns 404.

## 5.6 Environment variables

| Variable | Default | Meaning |
|----------|---------|---------|
| `ZALOS_DATA_DIR` | `./data` | SQLite DB, server static key, temp files. |
| `ZALOS_UPLOAD_TMP_DIR` | under data dir | Upload staging directory (tmpfs in containers). |
| `ZALOS_WEB_DIR` | unset (image sets it) | Directory of the Flutter web build to serve. Unset = no web client. |
| `ZALOS_PUBLIC_HOST` / `ZALOS_PUBLIC_PORT` | `127.0.0.1` / listen port | Address advertised in pairing URIs in local/container mode. |
| `ZALOS_CONTAINER`, `ZALOS_ALLOW_LOCAL` | unset | Both `1` are required for `serve --local`. |
| `ZALOS_TAILSCALE_SOCKET` | system socket | tailscaled socket path (sidecar mode). |
| `ZALOS_RTC_PORT_MIN` / `ZALOS_RTC_PORT_MAX` | `40000` / `40050` | UDP range for the call media gateway. Publish the same range. |
| `ZALOS_ICE_SERVERS` | Google STUN | JSON array of `RTCIceServer` objects for the call media gateway. |
| `ZALOS_MEDIA_ALLOWLIST_ONLY` | unset | `1` = media fetches only to the Zalo/CDN allowlist. |
| `ZALOS_ALLOW_INSECURE_MEDIA_HTTP` | unset | `1` allows plain-HTTP media (tests only). |
| `ZALOS_AUDIT_LOG` | unset | `1` enables the structured audit log. |
| `ZALOS_OA_POLL_MS` / `ZALOS_OA_POLL_IDLE_MS` | `5000` / `30000` | Official Account polling intervals. |
| `ZALOS_ZCA_DISPLACED_MS` | `300000` | Wait before reconnecting after Zalo Web was opened elsewhere. |
| `ZALOS_ZALO_MOCK_URL` | unset | Point the gateway at the offline mock (dev/e2e). |
| `TZ` | `Asia/Ho_Chi_Minh` in compose | Container time zone. |

## 5.7 Operating a server

```bash
docker exec <c> zalos devices list --all
docker exec <c> zalos devices revoke <deviceId>
docker exec <c> zalos accounts list
docker exec <c> zalos pair --role member      # pairing code for another device
docker exec <c> zalos doctor
```

Prefer logging in Zalo accounts from the app (**Me → Accounts**). The CLI
`accounts add` writes the QR to `/var/lib/zalos/tmp/login-qr.png`; copy it out
with `docker cp`.

Next: [6. Conventions](06-conventions.md).
