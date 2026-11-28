# 4. Kiểm thử và CI

> English: [../en/04-testing-and-ci.md](../en/04-testing-and-ci.md) · Về [mục lục](README.md)

## 4.1 Các bộ test

| Tầng | Lệnh | Ghi chú |
|------|------|---------|
| Mật mã Rust | `cargo test -p zalos-noise -p zalos-vault` | Thêm test vector cho mọi thay đổi crypto. |
| Zalo SDK | `cd packages/zalo-sdk && bun test` | Unit test với `fetch`/WebSocket giả. Không gọi mạng. |
| Server | `cd server && bunx tsc --noEmit && bun test` | Khoảng 390 test, ~45 giây. Dùng fake gateway; không gọi mạng. |
| Server e2e | `cd server && bun run test:e2e` | Cần mock offline đang chạy (`docker compose -f mock/compose.yaml up -d --build`). `bun test` thường sẽ bỏ qua. |
| Client | `cd client && flutter analyze && flutter test` | Test widget và data trong `client/test/{data,ui,support}`. |
| Landing | `cd landing && bun run lint && bun run build` | Lỗi kiểu và lỗi lint làm build thất bại. |
| Smoke container | `deploy/docker/smoke.sh` | Kiểm tra nhanh trên image đã build. |

Chạy một file test server: `bun test test/pairing.test.ts`. Lọc theo tên:
`bun test -t "pair"`.

Helper cho test server nằm trong `server/test/support/` (`client.ts` là client
Noise thật cho test RPC end-to-end, `helpers.ts` dựng server với fake gateway).
Hãy dùng chúng thay vì tự dựng.

## 4.2 CI kiểm tra gì

`.github/workflows/security.yml` chạy với mọi lần push lên `main` và mọi pull
request:

1. **Cổng test bảo mật**: test Rust (`--locked`), `bun install --frozen-lockfile`,
   `bunx tsc --noEmit`, và các bộ test server quan trọng về bảo mật (security,
   security-architecture, security-phase2, pairing, vault-integ, zca-hardening,
   review-fixes, doctor, local-mode, upload-staging).
2. **Quét lỗ hổng và bí mật**: OSV-Scanner trên lockfile của Bun, Rust và Flutter,
   `cargo audit`, Gitleaks trên toàn bộ lịch sử.
3. **SBOM**: SBOM CycloneDX kèm checksum SHA-256, upload thành artifact.

CI không chạy toàn bộ bộ test server hay test Flutter, nên hãy **chạy chúng ở máy**
trước khi push.

## 4.3 Xác minh một thay đổi

Chọn cách kiểm tra nhỏ nhất đủ chứng minh, rồi mở rộng dần:

1. Unit test cho phần code bạn sửa.
2. Toàn bộ bộ test của tầng bạn động vào.
3. Với thay đổi giao thức, gateway hay SDK: bộ e2e trên mock.
4. Với thay đổi UI: chạy app và nhìn tận mắt, cả sáng lẫn tối, cả màn hẹp lẫn rộng.
5. Với mọi thứ chạm tới Zalo thật: một lần chạy cẩn thận trên server đã triển
   khai, đọc `docker logs` (lỗi đăng nhập QR được ghi là `login QR failed: ...`).

Với mỗi bug bạn sửa, hãy viết một test **fail trước khi sửa**. Nếu không tái hiện
được bằng test, ghi rõ điều đó trong PR.

## 4.4 Các vùng nhạy cảm bảo mật

Thay đổi ở đây cần test trong các bộ test bảo mật và thêm một người review:

- `crates/*`, `server/src/tunnel/*`, `server/src/methods/pair.ts`,
  `server/src/methods/control.ts` (vai trò, ACL), `server/src/vault.ts`,
  `server/src/media.ts` (chống SSRF), `server/src/web_static.ts` (CSP/COOP/COEP),
  `server/src/doctor.ts`, `deploy/docker/*`.

Tiếp theo: [5. Triển khai](05-deployment.md).
