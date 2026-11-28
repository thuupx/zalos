# Onboarding cho lập trình viên zalos (Tiếng Việt)

> English: [../en/README.md](../en/README.md)

Chào mừng bạn đến với zalos. Bộ hướng dẫn này đưa bạn từ lúc vừa clone repo đến
lúc tự tin đưa một thay đổi lên production. Lần đầu hãy đọc theo thứ tự, sau đó
dùng như tài liệu tra cứu.

## zalos là gì

zalos cho phép **dùng một tài khoản Zalo trên nhiều thiết bị**, và **quản lý
nhiều tài khoản Zalo (cá nhân lẫn Official Account) trong một ứng dụng**, thông
qua một server do chính người dùng tự host. Không có gì tập trung cả.

```
Flutter client (iOS, Android, macOS, Windows, Linux, Web)
   |  WebSocket, mỗi channel là một phiên Noise IKpsk2
zalos server (Bun + TypeScript + SQLite)
   |  @zalos/zalo-sdk (giao thức Zalo Web) / OA OpenAPI
Zalo
```

Server là nơi lưu trữ chính (system of record): nó giữ một phiên Zalo Web cho mỗi
tài khoản, lưu mọi tin nhắn và sự kiện vào SQLite, rồi đồng bộ trạng thái tới mọi
thiết bị đã ghép cặp. Khoá vault dùng để mã hoá nội dung tin nhắn khi lưu trữ thì
nằm ở phía client.

## Thứ tự đọc

| # | Hướng dẫn | Bạn sẽ nắm được |
|---|-----------|-----------------|
| 1 | [Cài đặt](01-setup.md) | Toolchain, clone, build và chạy test lần đầu cho từng tầng |
| 2 | [Kiến trúc](02-architecture.md) | Thành phần, channel, framing, đồng bộ, vault, gateway, SDK |
| 3 | [Quy trình phát triển](03-development.md) | Chạy server và client ở máy, Zalo giả lập (fake/mock), công thức cho các thay đổi thường gặp |
| 4 | [Kiểm thử và CI](04-testing-and-ci.md) | Các bộ test, CI kiểm tra gì, cách xác minh một thay đổi |
| 5 | [Triển khai](05-deployment.md) | Docker + Tailscale, chế độ local, NAS, HTTPS cho web client, nâng cấp |
| 6 | [Quy ước](06-conventions.md) | Phong cách code, commit, quy tắc bảo mật, làm việc với tài khoản Zalo thật |
| 7 | [Xử lý sự cố](07-troubleshooting.md) | Các lỗi đã gặp và cách khắc phục |

Tài liệu chuyên sâu (đọc khi động vào phần đó, hiện chỉ có tiếng Anh):

- [docs/DESIGN.md](../../DESIGN.md): giao thức trên dây, danh sách RPC, thiết kế vault.
- [docs/SECURITY_ARCHITECT.md](../../SECURITY_ARCHITECT.md): mô hình mối đe doạ và các biện pháp bảo vệ.
- [docs/ZALO_SDK_AND_CALLS.md](../../ZALO_SDK_AND_CALLS.md):
  SDK Zalo nội bộ và hệ thống gọi thoại/video.

## Bản đồ repo

| Đường dẫn | Chứa gì |
|-----------|---------|
| `crates/zalos-noise` | Wrapper Noise bằng Rust (`snow`). Nơi duy nhất chạy Noise. |
| `crates/zalos-vault` | Vault HPKE (RFC 9180) bằng Rust, dẫn xuất khoá, `zeroize`. |
| `crates/*-wasm` | Wrapper wasm-bindgen của hai crate trên cho server Bun. |
| `server/` | Server Bun + TypeScript: tunnel, các RPC method, account manager, store, CLI. |
| `server/vendor/` | Bản build wasm của các crate, được commit (build lại bằng `scripts/build-*-wasm.sh`). |
| `packages/zalo-sdk` | `@zalos/zalo-sdk`, client giao thức Zalo Web/PC của chúng ta. |
| `client/` | App Flutter. Crate Rust FFI ở `client/rust`, binding ở `lib/src/rust_lib`. |
| `mock/` | Backend Zalo chạy offline (WireMock + gateway Bun) cho test end-to-end. |
| `deploy/` | Docker image và các file compose đã gia cố, systemd unit, script cài đặt. |
| `scripts/` | Script build wasm, web client, icon. |
| `landing/` | Trang giới thiệu (Next.js + shadcn, deploy lên Vercel). |
| `.claude/skills/` | Skill cho agent hỗ trợ onboarding và các tác vụ thường gặp. |

## Thuật ngữ

| Thuật ngữ | Nghĩa |
|-----------|-------|
| **slot** | Id ngẫu nhiên phía server của một tài khoản Zalo. Không bao giờ là uid Zalo. |
| **channel** | Một WebSocket chứa một phiên Noise: `pair`, `control` hoặc `account/<slot>`. |
| **pairing** | Mã dùng một lần, hết hạn sau 10 phút (`zalos://pair?d=...`) để đăng ký thiết bị. |
| **admin / member** | Vai trò thiết bị. Admin ghép cặp và thu hồi thiết bị, sửa ACL, đăng nhập tài khoản Zalo. |
| **ACL** | Danh sách slot mà một thiết bị được mở. Mặc định rỗng với member mới. |
| **seq** | Bộ đếm sự kiện tăng dần theo từng tài khoản, dùng để đồng bộ đa thiết bị. |
| **vault** | Khoá HPKE do client giữ, dùng để niêm phong nội dung tin nhắn và media cache khi lưu trữ. |
| **gateway** | Lớp chuyển tiếp từ server tới Zalo: `zca.ts` (tài khoản cá nhân, qua SDK), `oa.ts` (Official Account), `fake.ts`/`mock.ts` (test). |
| **tailnet** | Mạng riêng Tailscale mà server được thiết kế để chạy trong đó. |

## Nhờ agent hỗ trợ

Repo có sẵn các skill cho Claude Code trong `.claude/skills/`:

- `zalos-onboarding`: trả lời các câu "làm sao để ..." về repo, dẫn lập trình viên
  mới đi qua các bước cài đặt và chỉ đúng file cần xem.
- `zalos-dev-tasks`: hướng dẫn từng bước cho các thay đổi thường gặp (RPC method
  mới, chuỗi UI mới, đổi API Rust, endpoint SDK) kèm các lệnh kiểm tra cần chạy.

Mở repo trong Claude Code và hỏi, ví dụ: "giúp mình cài đặt môi trường dev cho
zalos" hoặc "thêm RPC method trả về danh sách tin ghim của cuộc trò chuyện".
