# 7. Xử lý sự cố

> English: [../en/07-troubleshooting.md](../en/07-troubleshooting.md) · Về [mục lục](README.md)

Mỗi mục gồm: triệu chứng, nguyên nhân, cách sửa. Phần lớn đã gặp trong các lần
triển khai thật.

## Web client

**Trang trắng trên mọi trình duyệt (kể cả Safari/Chrome trên iOS).**
CSP đã chặn thứ mà runtime Flutter web cần. Mở console của trình duyệt. Các
nguyên nhân đã biết, đều đã sửa trong `server/src/web_static.ts` và Dockerfile:
- CanvasKit tải từ `www.gstatic.com` → build bằng
  `flutter build web --release --no-web-resources-cdn`.
- `flutter_rust_bridge` nạp phần glue wasm bằng `new Function(...)` → CSP cần
  `'unsafe-eval'` trong `script-src`.
- `<base href="/">` bị chặn bởi `base-uri 'none'` → dùng `base-uri 'self'`.
- Font dự phòng từ `fonts.gstatic.com` → đã cho phép trong `connect-src`.

**"SharedArrayBuffer is not defined" / ghép cặp trên web không bao giờ xong.**
Trang chưa được cross-origin isolate hoặc không phải secure context. Phục vụ qua
HTTPS (`tailscale serve`) hoặc `localhost`, với COOP `same-origin` + COEP
`require-corp`. `http://100.x.y.z:7443` không chạy được.

**Thử WebSocket trả 404.** Bạn thử ở `/` (không phải route của tunnel) hoặc dùng
HTTP/2. Dùng `--http1.1` và `/v1/control`; kết quả đúng là `101`.

## Ghép cặp

**"the server has not recorded a listen address; run `zalos serve` first".**
`zalos pair` đọc địa chỉ listen mà server đang chạy đã lưu. Hãy chạy server với
cùng `ZALOS_DATA_DIR` trước.

**Mã hết hạn / đã dùng.** Mã ghép cặp chỉ dùng một lần và hết hạn sau 10 phút. Tạo
mã mới.

**Thiết bị đã ghép cặp nhưng không thấy tài khoản nào.** Member mới có ACL rỗng.
Admin cấp slot trong mục **Thiết bị** (hoặc `devices.setAcl`).

**Android emulator không kết nối được server dev.** Chạy
`adb reverse tcp:7443 tcp:7443`.

## Đăng nhập Zalo

**Đăng nhập QR lỗi ngay với `Truy cập không hợp lệ` (mã -4).**
`id.zalo.me` từ chối request QR nếu `Origin`/`Referer` không phải trang đăng nhập
của nó. Đã sửa trong `packages/zalo-sdk/src/auth/login-qr.ts` (`ID_PAGE_HEADERS`).
Nếu lỗi quay lại, hãy so header của chúng ta với header mà trang đăng nhập web chính
thức gửi.

**Điện thoại đã xác nhận nhưng zalos báo thất bại
(`Failed to confirm logged-in state via /jr/userinfo`).** Cookie phiên do
`id.zalo.me` đặt cho `chat.zalo.me` bị cookie jar quá chặt loại bỏ. Đã sửa trong
`packages/zalo-sdk/src/core/cookies.ts`. Thông báo lỗi giờ có danh sách bước
redirect và tên cookie; đọc chúng trong `docker logs` trước khi thử lại.

**QR hết hạn trước khi kịp quét.** Mã QR của Zalo sống khoảng 100 giây và app tự
làm mới. Ảnh chụp mã cũ không dùng được. Nếu zalos chạy trên cùng điện thoại với
Zalo, hãy mở zalos trên màn hình khác (máy tính hoặc web), hoặc dùng tính năng "quét
từ ảnh" của Zalo thật nhanh.

**Tài khoản liên tục bị offline.** Zalo chỉ cho một phiên web mỗi tài khoản. Có ai
đó đã mở Zalo Web (hoặc Zalo PC ở chế độ web) cho tài khoản đó; server sẽ chờ
`ZALOS_ZCA_DISPLACED_MS` rồi kết nối lại. Hãy đóng phiên web kia.

## Build

**Lần build Docker đầu tiên rất lâu.** Đây là chuyện bình thường: nó biên dịch
wasm-pack, flutter_rust_bridge_codegen, bundle wasm Rust và Flutter web. Trên máy
yếu hãy chạy dưới `nohup` và theo dõi log.

**Thiếu `web/pkg`.** Chạy `scripts/build-noise-web.sh` một lần (Rust nightly có
`rust-src` và target `wasm32-unknown-unknown`).

**Binding Dart lỗi thời sau khi sửa Rust.** Chạy `flutter_rust_bridge_codegen generate`
trong `client/`; phiên bản phải khớp (2.12.0).

**Build release macOS báo lỗi entitlement keychain.** Xem mục "macOS signing"
trong `client/README.md`: bản không ký dùng login keychain.

## Server không có git (ví dụ Synology NAS)

Dùng git qua container, ví dụ một script wrapper:

```sh
#!/bin/sh
exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":"$PWD" -w "$PWD" alpine/git:latest "$@"
```

Đặt nó lên đầu `PATH` khi chạy `git pull` trên NAS.

Về [mục lục](README.md).
