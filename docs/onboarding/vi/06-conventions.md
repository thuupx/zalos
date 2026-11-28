# 6. Quy ước

> English: [../en/06-conventions.md](../en/06-conventions.md) · Về [mục lục](README.md)

## 6.1 Ngôn ngữ

- **Code, comment, commit message, tài liệu trong repo: tiếng Anh.** Riêng bộ
  onboarding có cả tiếng Anh và tiếng Việt; khi sửa một bản thì cập nhật bản còn lại.
- **Chuỗi UI: tiếng Việt trước**, tiếng Anh sau, cả hai qua bảng l10n.

## 6.2 Commit và nhánh

- Tiêu đề theo kiểu Conventional Commits, dạng mệnh lệnh, chữ thường, không có dấu
  chấm cuối: `fix: keep Zalo session cookies through QR login`,
  `feat: add mention jump navigation`, `chore: bump client build to 16`,
  `docs: add bilingual onboarding guide`.
- Các type đang dùng: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `perf`, `ci`.
- Phần thân: cái gì hỏng hoặc thiếu, nguyên nhân gốc, và thay đổi làm gì. Ngắt dòng
  khoảng 72 cột.
- Mỗi commit một thay đổi logic. Không trộn chỉnh format với thay đổi hành vi.
- Tạo nhánh từ `main` (`feat/<chủ-đề>`, `fix/<chủ-đề>`), mở PR, giữ CI xanh.

## 6.3 Phong cách code

**TypeScript (server, SDK, landing)**

- TypeScript strict; `bunx tsc --noEmit` phải sạch. Không dùng `any` nếu không có
  comment giải thích lý do.
- Kiểm tra mọi tham số RPC ngay tại biên (`String(...)`, kiểm tra enum, giới hạn
  kích thước). Không bao giờ tin input từ client, kể cả thiết bị đã ghép cặp.
- Ưu tiên hàm nhỏ, thuần; giữ lời gọi Zalo trong gateway/SDK, lưu trữ trong
  `store/`, điều phối trong `accounts/manager.ts`.
- Comment giải thích **tại sao** (đặc thù giao thức, lý do bảo mật), không giải
  thích code làm gì.

**Dart (client)**

- `flutter analyze` sạch (`analysis_options.yaml`).
- UI phụ thuộc vào interface trong `domain/services.dart`, không gọi thẳng class data.
- Màu lấy từ `ZalosTokens`, chữ lấy từ `S.t()`, icon lấy từ `z_icons.dart`.
- Không sửa tay binding sinh tự động trong `lib/src/rust_lib/`; hãy sinh lại.

**Rust**

- Toàn bộ crypto nằm ở đây. Xoá sạch bí mật trong bộ nhớ (`zeroize`), không
  `unwrap()` trên dữ liệu đầu vào, có test cho mọi API.

## 6.4 An toàn tài khoản Zalo

zalos dùng giao thức web không chính thức của Zalo. Zalo có thể hạn chế hoặc khoá
những tài khoản hoạt động giống bot. Quy tắc:

- **Phát triển trên fake gateway hoặc mock.** Chỉ động vào Zalo thật để xác minh
  lần cuối, bằng tài khoản của chính bạn, và càng ít lần càng tốt.
- **Không bao giờ làm tăng lượng request.** Một thao tác của người dùng = tối đa một
  lời gọi Zalo. Giữ hàng đợi gửi 300 ms mỗi tài khoản. Không poll liên tục vào Zalo,
  không cào dữ liệu hàng loạt, không retry mà không có backoff.
- **Bắt chước chính xác web client chính thức** (endpoint, header như
  `Origin`/`Referer`, tham số). Nếu Zalo từ chối một request, hãy tìm xem client
  thật gửi gì; đừng thử bừa các biến thể lên production.
- **Đăng nhập QR** là thao tác bình thường của người dùng, nhưng thất bại lặp lại
  nhiều lần sẽ gây chú ý: hãy chẩn đoán qua log (`login QR failed: ...`) trước khi
  nhờ ai đó quét lại.
- Mở Zalo Web hoặc Zalo PC ở chế độ web ở nơi khác sẽ đẩy phiên của server ra;
  server sẽ lùi lại (`ZALOS_ZCA_DISPLACED_MS`) thay vì giành lại phiên.

## 6.5 Quy tắc bảo mật

- Không bao giờ commit bí mật: `.env`, `server/data*/`, cookie, thông tin đăng
  nhập Zalo, URI ghép cặp, bản ghi lưu lượng trong `.research/`, khoá riêng.
  Gitleaks chạy trong CI.
- URI ghép cặp và QR đăng nhập là bí mật khi còn hiệu lực. Không dán vào issue, PR
  hay nhật ký chat mà người khác đọc được.
- Không nới lỏng các bước kiểm tra của `doctor`, cấu hình gia cố container
  (`read_only`, `cap_drop: ALL`, `no-new-privileges`, uid không phải root 10001),
  header CSP/COOP/COEP, lớp chống SSRF hay kiểm tra vai trò/ACL, trừ khi có lý do
  đã được review và ghi rõ trong PR.
- Không đưa server ra internet công cộng. Dùng Tailscale (`tailscale serve` cho
  HTTPS); không dùng `tailscale funnel` hay port-forward cổng 7443.

## 6.6 Tài liệu

- Thay đổi hành vi hoặc giao thức → cập nhật `docs/DESIGN.md`.
- Thay đổi biện pháp bảo mật → cập nhật `docs/SECURITY_ARCHITECT.md`.
- Thay đổi cách cài đặt, quy trình hoặc triển khai → cập nhật onboarding ở cả hai
  ngôn ngữ.

Tiếp theo: [7. Xử lý sự cố](07-troubleshooting.md).
