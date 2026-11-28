# 5. Triển khai

> English: [../en/05-deployment.md](../en/05-deployment.md) · Về [mục lục](README.md)

zalos được thiết kế để chạy **riêng tư**, trên máy của bạn, chỉ truy cập được qua
tailnet Tailscale. Không bao giờ mở cổng 7443 ra internet công cộng.

## 5.1 Tổng quan các lựa chọn

| Lựa chọn | File | Khi nào |
|----------|------|---------|
| Docker + Tailscale sidecar | `deploy/docker/compose.yaml` (+ `compose.sidecar-ro.yaml`) | Khuyến nghị. Container tự vào tailnet, không publish cổng nào. |
| Chế độ container local | `deploy/docker/compose.local.yaml` | Host đã chạy Tailscale, hoặc bạn chỉ cần loopback. |
| Biến thể NAS / Tailscale trên host | `deploy/docker/compose.nas.yaml` | Giống chế độ local, bind vào `127.0.0.1`, public host là IP tailnet. |
| systemd trên Linux thuần | `deploy/install.sh` + `deploy/zalos.service` | Không dùng Docker. Cài Bun 1.4.4 và user `zalos`. |

Mọi image đều build bundle wasm Rust và web client Flutter, nên **lần build đầu
rất chậm** (vài chục phút trên CPU yếu). Các lần sau dùng lại cache.

## 5.2 Docker + Tailscale sidecar

```bash
cd deploy/docker
cp .env.example .env            # TS_AUTHKEY (không bắt buộc), TS_HOSTNAME, TZ, ZALOS_PORT
docker compose up -d --build
docker compose logs -f tailscale   # duyệt URL đăng nhập nếu để trống TS_AUTHKEY
docker compose exec zalos zalos pair --role admin
```

Để giữ socket điều khiển của Tailscale ngoài container app:

```bash
docker compose -f compose.yaml -f compose.sidecar-ro.yaml up -d
```

## 5.3 Chế độ container local

```bash
cd deploy/docker
ZALOS_BIND_HOST=127.0.0.1 ZALOS_PUBLIC_HOST=127.0.0.1 \
  docker compose -f compose.local.yaml up -d --build
docker compose -f compose.local.yaml exec zalos zalos pair --role admin
```

`ZALOS_PUBLIC_HOST` là địa chỉ được ghi vào URI ghép cặp. Đặt nó thành IP tailnet
của host (`tailscale ip -4`) để các thiết bị khác trong tailnet ghép cặp được. Chế
độ local chạy `zalos doctor` trước và từ chối khởi động nếu có lỗi nghiêm trọng.

## 5.4 HTTPS cho web client

Web client cần secure context (SharedArrayBuffer và secure storage).
`http://100.x.y.z:7443` trên tailnet là **chưa đủ**. Trên host:

```bash
tailscale serve --bg --https=443 http://127.0.0.1:7443
# web client: https://<máy>.<tailnet>.ts.net/
```

Qua HTTPS, web client mở `wss://` tới chính origin của trang, nên URI ghép cặp chứa
IP tailnet vẫn dùng được. Server gửi header COOP/COEP/CSP từ
`server/src/web_static.ts`; CSP cho phép `'unsafe-eval'` (cần cho trình nạp wasm
của flutter_rust_bridge) và `fonts.gstatic.com` (font dự phòng của Flutter).
CanvasKit được đóng gói sẵn (`--no-web-resources-cdn`).

## 5.5 Nâng cấp

```bash
git pull --ff-only
docker compose -f deploy/docker/<file>.yaml build      # chậm trên máy yếu; chạy với nohup
docker compose -f deploy/docker/<file>.yaml up -d
docker logs --tail 20 <container>                      # cần thấy "zalos listening on ws://..."
```

Dữ liệu nằm trong volume `zalos-data` (`/var/lib/zalos`); build lại image vẫn giữ
nguyên thiết bị đã ghép cặp và phiên Zalo. Hãy sao lưu volume trước những lần nâng
cấp rủi ro.

Kiểm tra sau khi nâng cấp:

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://<máy>.<tailnet>.ts.net/                # 200
curl -s --http1.1 -o /dev/null -w "%{http_code}\n" \
  -H "Connection: Upgrade" -H "Upgrade: websocket" -H "Sec-WebSocket-Version: 13" \
  -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
  https://<máy>.<tailnet>.ts.net/v1/control                                            # 101
docker exec <container> zalos accounts list                                             # tài khoản online
```

Phép thử WebSocket phải dùng HTTP/1.1; qua HTTP/2 lệnh upgrade sẽ trả 404.

## 5.6 Biến môi trường

| Biến | Mặc định | Ý nghĩa |
|------|----------|---------|
| `ZALOS_DATA_DIR` | `./data` | Database SQLite, khoá tĩnh của server, file tạm. |
| `ZALOS_UPLOAD_TMP_DIR` | trong thư mục data | Thư mục chứa upload tạm (tmpfs trong container). |
| `ZALOS_WEB_DIR` | không đặt (image tự đặt) | Thư mục bản build web Flutter để phục vụ. Không đặt = không có web client. |
| `ZALOS_PUBLIC_HOST` / `ZALOS_PUBLIC_PORT` | `127.0.0.1` / cổng đang listen | Địa chỉ ghi vào URI ghép cặp ở chế độ local/container. |
| `ZALOS_CONTAINER`, `ZALOS_ALLOW_LOCAL` | không đặt | Cả hai bằng `1` mới chạy được `serve --local`. |
| `ZALOS_TAILSCALE_SOCKET` | socket hệ thống | Đường dẫn socket của tailscaled (chế độ sidecar). |
| `ZALOS_RTC_PORT_MIN` / `ZALOS_RTC_PORT_MAX` | `40000` / `40050` | Dải UDP cho media gateway của cuộc gọi. Publish đúng dải này. |
| `ZALOS_ICE_SERVERS` | STUN của Google | Mảng JSON các object `RTCIceServer` cho media gateway của cuộc gọi. |
| `ZALOS_MEDIA_ALLOWLIST_ONLY` | không đặt | `1` = chỉ tải media từ danh sách cho phép của Zalo/CDN. |
| `ZALOS_ALLOW_INSECURE_MEDIA_HTTP` | không đặt | `1` cho phép media qua HTTP thường (chỉ dùng cho test). |
| `ZALOS_AUDIT_LOG` | không đặt | `1` bật audit log có cấu trúc. |
| `ZALOS_OA_POLL_MS` / `ZALOS_OA_POLL_IDLE_MS` | `5000` / `30000` | Chu kỳ poll của Official Account. |
| `ZALOS_ZCA_DISPLACED_MS` | `300000` | Thời gian chờ trước khi kết nối lại khi Zalo Web bị mở ở nơi khác. |
| `ZALOS_ZALO_MOCK_URL` | không đặt | Trỏ gateway tới mock offline (dev/e2e). |
| `TZ` | `Asia/Ho_Chi_Minh` trong compose | Múi giờ của container. |

## 5.7 Vận hành server

```bash
docker exec <c> zalos devices list --all
docker exec <c> zalos devices revoke <deviceId>
docker exec <c> zalos accounts list
docker exec <c> zalos pair --role member      # mã ghép cặp cho thiết bị khác
docker exec <c> zalos doctor
```

Nên đăng nhập tài khoản Zalo từ app (**Me → Accounts**). Lệnh CLI `accounts add`
ghi QR vào `/var/lib/zalos/tmp/login-qr.png`; lấy ra bằng `docker cp`.

Tiếp theo: [6. Quy ước](06-conventions.md).
