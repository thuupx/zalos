# 2. Kiến trúc

> English: [../en/02-architecture.md](../en/02-architecture.md) · Về [mục lục](README.md)

Trang này giúp bạn có bức tranh tổng thể. Định dạng chính xác trên dây và toàn bộ
RPC nằm trong [docs/DESIGN.md](../../DESIGN.md); hãy đọc file đó trước khi sửa giao
thức.

## 2.1 Bức tranh lớn

```
 Thiết bị (Flutter)                   Server của bạn (Bun)                    Zalo
 ┌──────────────────┐   WebSocket   ┌─────────────────────────────┐
 │ iOS / Android    │  + Noise cho  │ tunnel/   Noise + framing    │
 │ macOS / Windows  │◄─mỗi channel─►│ methods/  xử lý RPC          │
 │ Linux / Web      │               │ accounts/ AccountManager     │──► giao thức Zalo Web
 │                  │               │ gateway/  zca | oa | fake    │    (@zalos/zalo-sdk)
 │ khoá vault chỉ   │               │ store/    SQLite (WAL)       │──► OA OpenAPI
 │ nằm ở đây        │               │ vault.ts  niêm phong bằng    │
 │                  │               │           khoá công khai     │
 └──────────────────┘               └─────────────────────────────┘
```

Ba ý tưởng giải thích phần lớn code:

1. **Server là nơi lưu trữ chính.** Zalo Web không có API "cuộc trò chuyện gần
   đây" và rất ít lịch sử, nên server lưu mọi tin nhắn và sự kiện nó thấy, rồi trả
   lịch sử từ SQLite.
2. **Mỗi tài khoản một phiên Zalo Web, nhiều thiết bị dùng chung.** Server giữ
   phiên; thiết bị chỉ nói chuyện với server. Một thao tác trên thiết bị không bao
   giờ bị nhân thành nhiều lời gọi tới Zalo, và lưu lượng gửi đi Zalo được giãn
   nhịp (hàng đợi 300 ms mỗi tài khoản) để giống người thật.
3. **Mật mã chỉ nằm trong Rust.** `crates/zalos-noise` (đường truyền) và
   `crates/zalos-vault` (lưu trữ) được biên dịch sang wasm cho server/web và thành
   thư viện native cho các client khác. Không ai tự viết crypto bằng TS hay Dart.

## 2.2 Đường truyền: channel và Noise

Mỗi WebSocket chứa đúng một phiên Noise
(`Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s`). Client luôn là bên khởi tạo và ghim
(pin) khoá tĩnh của server nhận được lúc ghép cặp.

| Channel | URL | psk | Dùng cho |
|---------|-----|-----|----------|
| pair | `/v1/pair/<pairingId>` | secret ghép cặp dùng một lần | đăng ký thiết bị mới |
| control | `/v1/control` | psk riêng của thiết bị | manifest, thiết bị, ghép cặp, đăng nhập Zalo, vault |
| account | `/v1/account/<slot>` | psk riêng của thiết bị + kiểm tra ACL | mọi thứ bên trong một tài khoản Zalo |

Đường dẫn URL chỉ để định tuyến và không được mã hoá; prologue của Noise ràng buộc
nó (`zalos/1/<kind>/...`), nên nếu route bị sửa thì handshake thất bại. Các mã đóng
kết nối `4001` (không được phép), `4002` (lỗi giao thức), `4004` (slot không còn),
`1013` (quá tải) cho client biết có nên kết nối lại hay không.

Framing bên trong Noise: `type:u8 | flags:u8 | stream:u32be | chunk`. Type 1 là
JSON (`request` / `response` / `event`), type 2 là dữ liệu blob được tham chiếu
bằng stream id (upload, download, ảnh QR).

Code: `server/src/tunnel/` (server, framer, rpc) và
`client/lib/src/data/protocol/` (noise_channel, frame_codec, managed_channel).

## 2.3 Ghép cặp và vai trò

1. Admin chạy `zalos pair --role admin|member` (hoặc dùng mục **Thiết bị** trong
   app) và nhận `zalos://pair?d=<base64url>`: host, port, pairing id, secret,
   khoá công khai của server. Dùng một lần, hết hạn sau 10 phút.
2. Thiết bị mở channel pair với secret đó làm psk, gửi
   `pair.complete {deviceName, boxPublicKey}` và nhận psk riêng của mình.
3. Thiết bị đầu tiên là admin. Admin ghép cặp và thu hồi thiết bị, đặt ACL, bắt
   đầu đăng nhập Zalo bằng QR và quản lý vault. Member mới không thấy tài khoản nào
   cho tới khi admin cấp quyền trong ACL.

Khi trang được phục vụ qua HTTPS, web client bỏ qua host trong URI ghép cặp và kết
nối `wss://` tới chính origin của trang (`client/lib/src/data/protocol/ws_uri.dart`).

## 2.4 Bên trong server

| File | Vai trò |
|------|---------|
| `src/cli.ts` | Các lệnh CLI, chế độ khởi động (`--dev`, `--fake`, `--local`). |
| `src/server.ts` | Nối store, account manager, tunnel và các bảng method. |
| `src/tunnel/server.ts` | HTTP server: định tuyến upgrade WebSocket, phiên Noise, phục vụ web client tĩnh. |
| `src/web_static.ts` | Phục vụ bản build web Flutter kèm header COOP/COEP/CSP. |
| `src/methods/pair.ts`, `control.ts`, `account.ts`, `account_extended.ts` | Bảng RPC method cho từng loại channel. |
| `src/accounts/manager.ts` | `AccountManager`: mỗi slot một gateway, event log, broadcast, hàng đợi gửi, kết nối lại, cuộc gọi. |
| `src/gateway/types.ts` | Interface `ZaloGateway` / `GatewayFactory`: ranh giới giữa zalos và Zalo. |
| `src/gateway/zca.ts`, `zca_extended.ts` | Gateway tài khoản cá nhân, xây trên `@zalos/zalo-sdk`. |
| `src/gateway/oa.ts` | Gateway Zalo Official Account (OpenAPI). |
| `src/gateway/fake.ts`, `mock.ts` | Bản giả trong bộ nhớ cho test/dev, và adapter cho mock offline. |
| `src/store/db.ts` | Schema và truy vấn SQLite (`bun:sqlite`, WAL, `secure_delete`). |
| `src/vault.ts` | Niêm phong bản ghi bằng khoá công khai vault của tài khoản. |
| `src/media.ts` | Tải/upload media có chống SSRF. |
| `src/security/audit.ts` | Audit log có cấu trúc, tự che bí mật. |
| `src/doctor.ts` | Các bước kiểm tra gia cố chạy trước `serve` ở chế độ container. |
| `src/accounts/call_*`, `zrtc_*` | Gọi thoại/video: tín hiệu ZRTC của Zalo và media gateway WebRTC cho client. |

Một RPC của account đi như sau:

```
client AccountSession._channel.request('messages.react', {...})
  -> tunnel/rpc.ts điều phối trên channel account
  -> methods/account.ts "messages.react"
  -> AccountManager.react(slot, ...)            (giãn nhịp, lưu, broadcast)
  -> ZaloGateway.react(...) trong gateway/zca.ts (-> @zalos/zalo-sdk -> Zalo)
  -> sự kiện được thêm vào log của slot với seq mới, đẩy tới mọi thiết bị
```

## 2.5 Đồng bộ đa thiết bị

Mỗi tài khoản có một event log chỉ-thêm với `seq` tăng dần và bền vững (không bao
giờ cấp lại, kể cả sau khi dọn log hay khởi động lại). Mọi thay đổi trạng thái được
thêm vào log và broadcast tới mọi thiết bị đang kết nối của tài khoản đó. Khi kết
nối (lại), client gọi `sync {sinceSeq}` và nhận phần còn thiếu, hoặc nhận `reset`
nếu đã tụt quá xa.

## 2.6 Vault (mã hoá khi lưu trữ)

- Thiết bị đầu tiên tạo **vault root** 32 byte, không bao giờ gửi lên server.
- Cặp khoá cho từng tài khoản được dẫn xuất từ root và slot; thiết bị chỉ upload
  khoá **công khai** (`vault.setKey`). Server dùng nó niêm phong nội dung tin nhắn,
  sự kiện tương ứng, media cache và file upload tạm, và không tự mở lại được.
- Siêu dữ liệu cần cho sắp xếp và thao tác (id, thời gian, loại, người gửi, số chưa
  đọc, tên cuộc trò chuyện) vẫn để dạng rõ.
- Thiết bị mới nhận root qua QR từ một thiết bị cũ (màn hình sang camera) hoặc qua
  một yêu cầu mà admin duyệt sau khi so khớp dấu vân tay khoá.
- Mất mọi thiết bị giữ root thì lịch sử không đọc được nữa; app cho phép xuất mã
  khôi phục, có xác thực sinh trắc học.

Chi tiết và giới hạn: [DESIGN.md "Vault"](../../DESIGN.md#vault-encryption-at-rest-with-client-held-keys)
và [SECURITY_ARCHITECT.md](../../SECURITY_ARCHITECT.md).

## 2.7 Zalo SDK (`packages/zalo-sdk`)

Bản cài đặt giao thức Zalo Web/PC bằng TypeScript của riêng zalos (đã thay `zca-js`):

- `core/http.ts`: profile header, xử lý cookie, envelope AES, chuyển domain dự phòng.
- `core/cookies.ts`: `ZaloCookieJar` (tough-cookie). Zalo đặt cookie phiên cho các
  host anh em (ví dụ `id.zalo.me` đặt cookie cho `chat.zalo.me`); jar lưu cookie
  thuộc domain Zalo theo đúng Domain mà Zalo khai báo.
- `auth/login-qr.ts`: luồng đăng nhập QR của `id.zalo.me`. Các endpoint này đòi
  `Origin`/`Referer` là trang đăng nhập.
- `ws/`: listener realtime (framing, handshake khoá mã hoá, các lệnh sự kiện).
- `apis/*`: các module theo miền (tin nhắn, nhóm, bảng tin, bạn bè, cuộc gọi, ...).

Hãy coi package này là code giao thức: mọi thay đổi phải đối chiếu với hành vi thật
và không được làm tăng số lượng request. Xem
[ZALO_SDK_MIGRATION_AND_CALLS.md](../../ZALO_SDK_MIGRATION_AND_CALLS.md).

## 2.8 Bên trong client

| Đường dẫn | Vai trò |
|-----------|---------|
| `lib/main.dart` | Điểm vào của app. |
| `lib/src/domain/models.dart`, `services.dart` | Model miền và interface service mà UI phụ thuộc. |
| `lib/src/data/` | Phần cài đặt: `server_link.dart` (channel control), `account_session.dart` (channel account, cài đặt các service), `pairing.dart`, `vault.dart`, `key_store.dart` (secure storage), `media_cache.dart`. |
| `lib/src/data/protocol/` | Kết nối WebSocket (io/web), channel Noise, codec frame, phân giải URI. |
| `lib/src/noise/`, `lib/src/rust_lib/` | Phía Dart của FFI Rust (binding được sinh tự động: không sửa tay). |
| `rust/` | Crate FFI cung cấp Noise và vault cho Dart qua flutter_rust_bridge 2.12.0. |
| `lib/src/ui/state/` | Các provider Riverpod (`app_state.dart`, media, notifications, thread UI). |
| `lib/src/ui/theme/` | `tokens.dart` (toàn bộ màu, sáng/tối), `theme.dart`, icon. |
| `lib/src/ui/l10n/` | Bảng chuỗi tự viết: `strings_vi.dart` (chính) và `strings_en.dart`. |
| `lib/src/ui/<feature>/` | Các màn hình: shell, threads, chat, contacts, groups, info, me, devices, pairing, vault, call, qr. |

Quản lý state dùng Riverpod 2.6. Bố cục tự thích ứng giữa di động (tab dưới) và
màn hình rộng (ba khung).

Tiếp theo: [3. Quy trình phát triển](03-development.md).
