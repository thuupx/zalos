# 1. Cài đặt

> English: [../en/01-setup.md](../en/01-setup.md) · Về [mục lục](README.md)

Mục tiêu của trang này: khi đọc xong, mọi tầng đều build được và test đều pass
trên máy bạn.

## 1.1 Toolchain

| Công cụ | Phiên bản | Cần cho | Cài đặt |
|---------|-----------|---------|---------|
| Git | bản gần đây | mọi thứ | gói hệ thống |
| Bun | **1.4.4** hoặc 1.4.x mới hơn (`engines.bun >= 1.4`) | server, SDK, mock, landing | `curl -fsSL https://bun.sh/install \| bash` |
| Rust | stable qua `rustup` | các crate, FFI của client | `curl https://sh.rustup.rs -sSf \| sh` |
| Rust nightly + `rust-src` + `wasm32-unknown-unknown` | nightly | chỉ cho wasm của web client | `rustup toolchain install nightly --component rust-src && rustup target add --toolchain nightly wasm32-unknown-unknown` |
| wasm-pack | **0.15.1** | build lại wasm cho server và web client | `cargo install --locked --version 0.15.1 wasm-pack` |
| flutter_rust_bridge_codegen | **2.12.0** (phải khớp `client/pubspec.yaml`) | sinh lại binding Dart, wasm cho web | `cargo install --locked --version 2.12.0 flutter_rust_bridge_codegen` |
| Flutter | **3.50.x** stable (Docker image ghim 3.50.1) | client | https://docs.flutter.dev/get-started |
| Xcode | bản hiện tại | build iOS / macOS | App Store |
| Android SDK + NDK | bản hiện tại | build Android | Android Studio |
| Docker + Compose v2 | bản hiện tại | triển khai, Zalo mock, e2e | Docker Desktop / OrbStack / gói của distro |
| Tailscale | bản hiện tại | triển khai thật | https://tailscale.com/download |

Trên Apple Silicon, bản build Flutter release (AOT) cần thêm Rosetta 2:
`softwareupdate --install-rosetta`.

Kiểm tra nhanh:

```bash
bun --version && cargo --version && flutter --version && docker compose version
```

## 1.2 Clone

```bash
git clone git@github.com:thuupx/zalos.git
cd zalos
```

Repo không có package manager chung ở thư mục gốc. Mỗi tầng tự cài dependency.

## 1.3 Các crate Rust

```bash
cargo test -p zalos-noise -p zalos-vault
```

**Toàn bộ** phần mật mã nằm trong các crate này. TypeScript và Dart không bao giờ
tự viết crypto; chúng gọi các crate này (wasm trên server và web, FFI native trên
các client khác).

Server dùng bản build wasm đã commit trong `server/vendor/`. Bạn chỉ build lại khi
sửa crate:

```bash
scripts/build-noise-wasm.sh   # -> server/vendor/zalos-noise/
scripts/build-vault-wasm.sh   # -> server/vendor/zalos-vault/
```

Commit phần `server/vendor/` mới sinh ra cùng với thay đổi ở crate.

## 1.4 Zalo SDK

```bash
cd packages/zalo-sdk
bun install
bun test
```

Server dùng `@zalos/zalo-sdk` qua `file:../packages/zalo-sdk`.

## 1.5 Server

```bash
cd server
bun install --frozen-lockfile
bunx tsc --noEmit          # kiểm tra kiểu
bun test                   # khoảng 390 test, mất ~45 giây
```

Điểm vào của CLI là `server/src/cli.ts` (`bun run src/cli.ts <lệnh>`, hoặc lệnh
`zalos` bên trong Docker image):

| Lệnh | Mục đích |
|------|----------|
| `serve [--dev] [--fake] [--local] [--port N] [--host H]` | Chạy server. |
| `pair [--role admin\|member]` | In URI ghép cặp và mã QR trên terminal. |
| `doctor` | Chạy các bước kiểm tra gia cố của host/container. |
| `health` | Healthcheck cho container (mở kết nối TCP tới địa chỉ đang listen). |
| `devices list [--all] \| revoke [--force] <id>` | Quản lý thiết bị đã ghép cặp. |
| `accounts list \| add \| add-oa \| remove <slot>` | Quản lý tài khoản Zalo (`add` = đăng nhập bằng QR trên terminal). |
| `fake incoming <slot> <threadId> <text> \| fake emit <slot> <json>` | Bơm sự kiện vào fake gateway (chỉ dùng khi dev). |
| `vault reset --yes` | Xoá trạng thái vault (nguy hiểm). |

Dữ liệu nằm trong `ZALOS_DATA_DIR` (mặc định `./data`): database SQLite, khoá tĩnh
của server, file tạm. **Không bao giờ commit `server/data/`.**

## 1.6 Flutter client

```bash
cd client
flutter pub get
flutter analyze
flutter test
flutter run -d macos        # hoặc iOS simulator, Android emulator, linux, windows
```

Khi build native, plugin `rust_builder/` (cargokit) tự biên dịch `client/rust` và
tự chạy `rustup target add` cho các target còn thiếu.

Web cần bundle wasm của flutter_rust_bridge trước (dùng Rust nightly, xem mục 1.1):

```bash
scripts/build-noise-web.sh    # build client/web/pkg/
scripts/dev-web.sh            # flutter run -d web-server trên 127.0.0.1:18934, kèm header COOP/COEP
```

Web client cần **cross-origin isolation** (SharedArrayBuffer), nên luôn phục vụ nó
với `Cross-Origin-Opener-Policy: same-origin` và
`Cross-Origin-Embedder-Policy: require-corp`, qua `localhost` hoặc HTTPS.
`scripts/dev-web.sh` và `scripts/serve-web.sh` đã làm sẵn việc này.

Sau khi sửa API Rust trong `client/rust/src/api/`, sinh lại binding:

```bash
cd client && flutter_rust_bridge_codegen generate
```

## 1.7 Trang landing (không bắt buộc)

```bash
cd landing
bun install
bun run dev     # http://localhost:3000
bun run lint && bun run build
```

## 1.8 Danh sách kiểm tra

- [ ] `cargo test -p zalos-noise -p zalos-vault` pass
- [ ] `packages/zalo-sdk`: `bun test` pass
- [ ] `server`: `bunx tsc --noEmit` và `bun test` pass
- [ ] `client`: `flutter analyze` sạch và `flutter test` pass
- [ ] Bạn chạy được client trên ít nhất một nền tảng

Tiếp theo: [2. Kiến trúc](02-architecture.md).
