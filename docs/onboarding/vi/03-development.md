# 3. Quy trình phát triển

> English: [../en/03-development.md](../en/03-development.md) · Về [mục lục](README.md)

## 3.1 Chọn backend Zalo

| Chế độ | Lệnh (trong `server/`) | Nói chuyện với | Dùng khi |
|--------|------------------------|----------------|----------|
| **Fake** | `bun run src/cli.ts serve --dev --fake` | fake gateway trong bộ nhớ | Làm UI, làm RPC, phát triển hằng ngày. Không cần tài khoản Zalo. |
| **Mock** | `ZALOS_ZALO_MOCK_URL=http://127.0.0.1:7355 bun run src/cli.ts serve --dev` | Zalo giả lập offline bằng WireMock (`mock/`) | chạy code SDK/gateway thật mà không cần Zalo |
| **Thật** | một server đã triển khai (xem [Triển khai](05-deployment.md)) | Zalo thật | chỉ để xác minh lần cuối |

Mặc định hãy dùng **fake**. Để Zalo thật cho lần kiểm tra cuối: fake gateway nhanh
hơn, không cần điện thoại, và không làm rối tài khoản thật bằng dữ liệu test (xem
[Quy ước](06-conventions.md#64-làm-việc-với-tài-khoản-zalo-thật)).

`--dev` chỉ bind vào loopback (`127.0.0.1`, `::1`, `localhost`) và từ chối chạy
dưới systemd. `--fake` bị từ chối nếu không có `--dev`.

## 3.2 Vòng lặp dev với fake gateway

Terminal 1, server:

```bash
cd server
export ZALOS_DATA_DIR=./data-dev        # tách dữ liệu dev khỏi mọi thứ khác
bun run src/cli.ts serve --dev --fake
# zalos listening on ws://127.0.0.1:7443
# fake admin hook on 127.0.0.1:<port>
```

Terminal 2, mã ghép cặp cho thiết bị đầu tiên (admin):

```bash
cd server
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts pair --role admin
```

Terminal 3, client:

```bash
cd client
flutter run -d macos     # dán URI zalos://pair?d=... vào màn hình ghép cặp
```

Sau đó trong app: **Me → Accounts → Thêm tài khoản**. Fake gateway trả lời đăng
nhập QR ngay lập tức với tài khoản "Fake Account".

Cho tài khoản giả nhận tin nhắn:

```bash
cd server
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts accounts list         # tìm slot
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts fake incoming <slot> <threadId> "xin chào từ fake"
ZALOS_DATA_DIR=./data-dev bun run src/cli.ts fake emit <slot> '<json sự kiện gateway>'
```

Làm lại từ đầu: dừng server và xoá `server/data-dev/`.

### Lưu ý theo thiết bị

- **iOS simulator / macOS / Linux / Windows**: dùng thẳng `127.0.0.1:7443`.
- **Android emulator**: `127.0.0.1` của emulator là chính nó. Hãy chuyển cổng:
  `adb reverse tcp:7443 tcp:7443`.
- **Điện thoại thật**: dùng server đã triển khai trên tailnet, hoặc chạy server ở
  chế độ container local (xem [Triển khai](05-deployment.md#53-chế-độ-container-local)).
- **Web**: chạy `scripts/build-noise-web.sh` một lần, rồi `scripts/dev-web.sh`
  (phục vụ ở `http://127.0.0.1:18934` kèm COOP/COEP). `localhost` được coi là
  secure context nên ghép cặp được mà không cần HTTPS.

## 3.3 Zalo giả lập offline

```bash
docker compose -f mock/compose.yaml up -d --build     # gateway ở 127.0.0.1:7355
cd server
ZALOS_ZALO_MOCK_URL=http://127.0.0.1:7355 bun run src/cli.ts serve --dev
bun run test:e2e                                       # bộ e2e chạy trên mock
```

Các stub nằm trong `mock/wiremock/mappings/` (JSON thuần, là phần bạn sửa). Dịch vụ
`mock/gateway/` lo phần mã hoá của Zalo và WebSocket. Đọc
[mock/README.md](../../../mock/README.md) trước khi thêm stub. Mock chứng minh phần
tích hợp của chúng ta, không chứng minh hành vi của Zalo thật.

## 3.4 Công thức

### Thêm RPC method cho channel account

1. **Ranh giới gateway** (chỉ khi cần gọi Zalo): thêm method vào `ZaloGateway`
   (hoặc `ZaloExtendedGateway`) trong `server/src/gateway/types.ts`.
2. **Cài đặt** trong `server/src/gateway/zca.ts` (qua `@zalos/zalo-sdk`) và trong
   `server/src/gateway/fake.ts` để chế độ dev và test vẫn chạy. Thêm bản cho OA
   trong `oa.ts` hoặc ném lỗi "không hỗ trợ" rõ ràng.
3. **Logic nghiệp vụ** trong `server/src/accounts/manager.ts` nếu thao tác cần giãn
   nhịp, lưu trữ hoặc broadcast (hầu hết thao tác ghi). Thêm sự kiện vào log của
   slot để các thiết bị khác thấy thay đổi.
4. **RPC handler** trong `server/src/methods/account.ts` (hoặc
   `account_extended.ts`): kiểm tra mọi tham số (`String(...)`, enum, kích thước),
   dùng `slotOf(ctx)`, trả về JSON gọn.
5. **Test** trong `server/test/` (dùng helper fake gateway trong `test/support/`).
   Chạy `bunx tsc --noEmit && bun test`.
6. **Client**: thêm method vào interface service trong
   `client/lib/src/domain/services.dart`, cài đặt trong
   `client/lib/src/data/account_session.dart` bằng
   `_channel.request('<method>', {...})`, xử lý sự kiện trong phần switch sự kiện
   của session, rồi nối vào UI/state.
7. **Chuỗi**: mọi chữ hiển thị mới phải có trong cả hai bảng l10n (bên dưới).
8. Cập nhật [docs/DESIGN.md](../../DESIGN.md) nếu danh sách RPC thay đổi.

### Thêm hoặc sửa chuỗi UI

- Thêm key vào `client/lib/src/ui/l10n/strings_vi.dart` **và** `strings_en.dart`.
  Tiếng Việt là chính; `S.t()` sẽ fallback về tiếng Việt.
- Dùng placeholder `{0}`, `{1}`: `strings.t('loginScanned', [name])`.
- Không bao giờ viết cứng chữ hiển thị trong widget.

### Đổi màu hoặc khoảng cách

Dùng token trong `client/lib/src/ui/theme/tokens.dart` (`ZalosTokens.light` và
`.darkTokens`). Không đặt `Color(0x...)` thô trong widget. Trang landing sao chép
các token này trong `landing/src/app/globals.css`; hãy giữ đồng bộ nếu đổi nhận
diện thương hiệu.

### Đổi API mật mã Rust

1. Sửa crate (`crates/zalos-noise` hoặc `crates/zalos-vault`) và test của nó:
   `cargo test -p zalos-noise -p zalos-vault`.
2. Server: `scripts/build-noise-wasm.sh` / `scripts/build-vault-wasm.sh`, commit
   phần sinh ra trong `server/vendor/`.
3. Client: cập nhật `client/rust/src/api/`, rồi chạy
   `flutter_rust_bridge_codegen generate` trong `client/`, và
   `scripts/build-noise-web.sh` cho web.
4. Chạy cả ba bộ test. Đây là phần nhạy cảm bảo mật: nhờ thêm một người review.

### Thêm hoặc sửa endpoint trong Zalo SDK

1. Tìm đúng hình dạng request thật (URL, method, tham số, header) từ một bản ghi
   lưu lượng đáng tin. Không đoán tham số.
2. Cài đặt trong module phù hợp ở `packages/zalo-sdk/src/apis/*.ts`, dùng lại
   helper của `ZaloHttpClient` (`getEncrypted`, `postEncrypted`, `resolveEnvelope`).
3. Thêm unit test trong `packages/zalo-sdk/test/` với `fetch` giả.
4. Đưa ra qua gateway (theo công thức ở trên).
5. Xác minh một lần với Zalo thật bằng số lời gọi ít nhất có thể.

### Thêm biến môi trường cho server

Đọc nó ở đúng một chỗ, có giá trị mặc định an toàn, ghi vào
[Triển khai](05-deployment.md#56-biến-môi-trường) và vào
`deploy/docker/compose*.yaml` nếu container cần. Không dùng biến môi trường cho bí
mật có thể lọt vào log.

## 3.5 Trước khi mở PR

- [ ] Đã thêm hoặc cập nhật test liên quan, mọi bộ test của các tầng bị sửa đều pass
- [ ] `flutter analyze` sạch nếu có sửa client
- [ ] Cả hai bảng l10n đã có chuỗi mới
- [ ] Không stage bí mật, token, cookie, `.env`, `server/data*` hay bản ghi lưu lượng
- [ ] Đã cập nhật tài liệu (DESIGN, onboarding) khi hành vi hoặc cách cài đặt thay đổi
- [ ] Commit message theo [Quy ước](06-conventions.md#62-commit-và-nhánh)

Tiếp theo: [4. Kiểm thử và CI](04-testing-and-ci.md).
