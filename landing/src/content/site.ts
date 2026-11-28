const links = {
  repo: "https://github.com/thuupx/zalos",
  onboardingVi:
    "https://github.com/thuupx/zalos/blob/main/docs/onboarding/vi/README.md",
  onboardingEn:
    "https://github.com/thuupx/zalos/blob/main/docs/onboarding/en/README.md",
  security:
    "https://github.com/thuupx/zalos/blob/main/docs/SECURITY_ARCHITECT.md",
}

const vi = {
  links,
  nav: {
    skipToContent: "Chuyển tới nội dung chính",
    ariaLabel: "Điều hướng chính",
    features: "Tính năng",
    howItWorks: "Cách hoạt động",
    security: "Bảo mật",
    quickStart: "Cài đặt",
    faq: "Hỏi đáp",
    github: "GitHub",
    openMenu: "Mở menu",
    mobileMenuTitle: "Menu",
  },
  controls: {
    languageLabel: "Ngôn ngữ",
    themeToggle: "Đổi giao diện sáng/tối",
    githubLabel: "Mã nguồn zalos trên GitHub",
  },
  hero: {
    badge: "Proxy Zalo tự host · Mã nguồn mở",
    title: "Dùng Zalo trên nhiều thiết bị qua server tự host",
    subtitle:
      "Zalo giới hạn một điện thoại và một máy tính, lại không có bản Linux. zalos giữ phiên đăng nhập trên server bạn tự chạy, đồng bộ tin nhắn, cuộc gọi và lịch sử về mọi thiết bị, hỗ trợ nhiều tài khoản cá nhân lẫn Zalo OA.",
    primaryCta: "Hướng dẫn cài đặt",
    secondaryCta: "Mã nguồn trên GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "Giao diện chat của zalos hiển thị một nhóm làm việc đang trao đổi, đồng bộ trên 3 thiết bị.",
      groupName: "Nhóm Sản phẩm",
      devices: "Đang đồng bộ · 3 thiết bị",
      pinned: "Ghim: Checklist phát hành bản 2.4",
      composerPlaceholder: "Nhập tin nhắn...",
      messages: [
        {
          side: "in",
          text: "Mình vừa đẩy bản sửa lỗi thanh toán lên staging rồi",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Ok để mình kiểm tra lại luồng QR rồi báo",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Xem thêm đơn có mã giảm giá nhé, hôm qua bị lệch tổng tiền",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Khớp rồi. 2h chiều nay đẩy lên production được không?",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "Được, lát mình gửi ghi chú phát hành vào nhóm trước",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Tính năng",
    title: "Các tính năng chính",
    intro:
      "Từ chat cá nhân, nhóm làm việc đến gọi thoại và quản lý OA. Mọi kết nối từ thiết bị chỉ đi qua server của bạn rồi mới chuyển tiếp tới Zalo.",
    items: [
      {
        title: "Nhiều tài khoản và phân quyền",
        description:
          "Gộp nhiều tài khoản cá nhân và Zalo OA vào cùng một ứng dụng. Mỗi thiết bị có vai trò admin hoặc member, chỉ mở được tài khoản do admin cấp quyền.",
        badge: null,
      },
      {
        title: "Đồng bộ nhiều thiết bị",
        description:
          "Tin nhắn, trạng thái đã xem, cảm xúc và đang nhập khớp nhau trên điện thoại, máy tính bảng, desktop (kể cả Linux) và trình duyệt web.",
        badge: null,
      },
      {
        title: "Không nặng bộ nhớ máy",
        description:
          "Lịch sử chat và media được lưu trong SQLite trên server, thiết bị chỉ tải nội dung khi cần mở. Điện thoại không còn bị Zalo chiếm hàng chục gigabyte.",
        badge: null,
      },
      {
        title: "Nhắn tin và gửi tệp",
        description:
          "Chat 1:1 và nhóm, trích dẫn, nhắc tên (@All), định dạng chữ, đánh dấu khẩn cấp, thu hồi, tin tự huỷ, tệp tới 100 MiB, tin nhắn thoại, sticker và tìm kiếm.",
        badge: null,
      },
      {
        title: "Bảng tin và tiện ích nhóm",
        description:
          "Ghim tin nhắn trong cả chat riêng lẫn nhóm, quản lý bảng tin, tạo bình chọn (nhiều lựa chọn, ẩn danh), ghi chú nhóm và đặt nhắc hẹn lặp lại.",
        badge: null,
      },
      {
        title: "Gọi thoại và video 1:1",
        description:
          "Gọi trực tiếp với người dùng Zalo thông thường qua cầu nối ZRTC sang WebRTC trên server. Tất cả thiết bị cùng đổ chuông, máy nào nhận trước sẽ bắt máy.",
        badge: null,
      },
      {
        title: "Danh bạ và quét QR",
        description:
          "Tìm người dùng theo số điện thoại, gửi và duyệt lời mời kết bạn, đặt biệt danh, chặn liên hệ và quét cả mã QR của Zalo lẫn mã ghép cặp zalos.",
        badge: null,
      },
      {
        title: "Quản lý hội thoại",
        description:
          "Ghim cuộc trò chuyện, tắt thông báo, gắn nhãn màu, lưu trữ, ẩn hội thoại sau mã PIN và đặt lịch tự xoá tin nhắn theo từng cuộc trò chuyện.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "Cách hoạt động",
    title: "Cách thiết lập và đồng bộ",
    intro:
      "Thiết bị không gọi thẳng tới Zalo. Server của bạn giữ một phiên Zalo Web cho mỗi tài khoản, giãn nhịp request như thao tác thật, lưu sự kiện vào SQLite rồi đẩy đồng bộ xuống các máy đã ghép cặp.",
    steps: [
      {
        title: "Chạy container zalos",
        description:
          "Khởi chạy bằng Docker Compose trên VPS, NAS hoặc máy cá nhân. Image đã đóng gói sẵn bản Flutter Web nên không cần dựng riêng frontend.",
      },
      {
        title: "Ghép cặp thiết bị",
        description:
          "Chạy lệnh zalos pair để tạo mã hoặc QR dùng một lần. Thiết bị đầu tiên mặc định là admin; các máy thêm sau nhận vai trò member với quyền truy cập rỗng cho tới khi được cấp.",
      },
      {
        title: "Đăng nhập tài khoản Zalo",
        description:
          "Quét mã QR từ app Zalo trên điện thoại hoặc thêm Zalo OA trong mục Tài khoản. Server sẽ bắt đầu nhận tin và đồng bộ về các thiết bị.",
      },
    ],
    architectureTitle: "Đường đi của kết nối",
    architecture: {
      clients: "Client Flutter",
      transport: "WebSocket + Noise IKpsk2",
      server: "Server zalos (Bun + SQLite)",
      zalo: "Zalo Web / OA API",
    },
  },
  security: {
    eyebrow: "Bảo mật",
    title: "Mã hoá bằng Rust, khoá giữ trên thiết bị",
    intro:
      "Toàn bộ phần mật mã nằm trong hai crate Rust (zalos-noise và zalos-vault), không tự viết lại bằng TypeScript hay Dart. Nếu ổ đĩa hoặc bản sao lưu SQLite trên server bị lộ, nội dung tin nhắn và media đã niêm phong vẫn không đọc được.",
    points: [
      {
        title: "Đường truyền Noise xác thực hai chiều",
        chip: "Noise_IKpsk2_25519",
        description:
          "Mọi kết nối WebSocket chạy Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s, ràng buộc theo từng route và ghim khoá tĩnh của server ngay từ lúc ghép cặp.",
      },
      {
        title: "Kho lưu trữ mã hoá bằng HPKE",
        chip: "HPKE · RFC 9180",
        description:
          "Nội dung tin nhắn và media cache được niêm phong trên server bằng khoá công khai của client. Khoá gốc 32 byte chỉ nằm trên thiết bị và hỗ trợ xoay khoá theo phiên bản.",
      },
      {
        title: "Ghép cặp một lần và phân quyền ACL",
        chip: "RBAC · 10m TTL",
        description:
          "Mã ghép cặp hết hạn sau 10 phút và chỉ dùng một lần. Thiết bị mới nhận PSK riêng, mặc định không có quyền xem tài khoản nào và có thể bị thu hồi ngay lập tức.",
      },
      {
        title: "Container chạy quyền tối thiểu",
        chip: "non-root · ro-fs",
        description:
          "Server chạy dưới user thường, root filesystem chỉ đọc, cắt bỏ Linux capabilities và có bước tự kiểm tra (zalos doctor) trước khi mở kết nối.",
      },
      {
        title: "Kiểm soát lưu lượng tải media",
        chip: "DNS-pinned SSRF",
        description:
          "Mọi lượt tải tệp và ảnh đều ghim địa chỉ IP lúc kết nối để chặn DNS rebinding, chặn hạ cấp HTTPS xuống HTTP và hỗ trợ giới hạn domain Zalo/CDN.",
      },
      {
        title: "Không cần mở port ra ngoài",
        chip: "Tailscale · tailnet",
        description:
          "Triển khai kèm sidecar Tailscale để giữ server trong mạng riêng. Khi cần dùng bản web qua HTTPS, chỉ cần bật tailscale serve mà không phải lộ cổng công khai.",
      },
    ],
    linkLabel: "Xem chi tiết tài liệu kiến trúc bảo mật",
  },
  quickStart: {
    eyebrow: "Cài đặt",
    title: "Triển khai server và chạy app",
    intro:
      "Dùng Docker + Tailscale nếu muốn truy cập từ xa an toàn, chạy chế độ local để thử nhanh trên máy, hoặc tự build client Flutter từ mã nguồn. Lần build Docker đầu tiên sẽ mất vài phút do biên dịch Rust WASM và Flutter Web.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Chạy local",
      client: "Flutter client",
    },
    copy: "Sao chép",
    copied: "Đã chép",
    copyLabel: "Sao chép lệnh",
    scrollLabel: "Cuộn ngang để xem đầy đủ câu lệnh",
    note: "Chi tiết cấu hình môi trường, NAS và xử lý lỗi có trong",
    noteLink: "tài liệu onboarding",
  },
  faq: {
    eyebrow: "Hỏi đáp",
    title: "Câu hỏi thường gặp",
    intro:
      "Một vài chi tiết về cách lưu dữ liệu, mạng nội bộ và phiên Zalo Web trước khi bạn dựng server.",
    items: [
      {
        question: "zalos có phải sản phẩm chính thức của Zalo không?",
        answer:
          "Không. Đây là dự án mã nguồn mở độc lập, không liên quan tới Zalo hay VNG. Tài khoản cá nhân kết nối như một phiên Zalo Web thông thường; riêng Zalo OA dùng OpenAPI chính thức.",
      },
      {
        question: "Dữ liệu tin nhắn được lưu ở đâu và server có đọc được không?",
        answer:
          "Toàn bộ dữ liệu nằm trên server bạn tự chạy, không đi qua bên thứ ba. Nội dung tin nhắn và media cache được mã hoá bằng HPKE với khoá giữ trên thiết bị, nên server không tự giải mã được lịch sử. Metadata như ID cuộc trò chuyện, thời gian, người gửi và số chưa đọc được giữ dạng rõ để phục vụ đồng bộ.",
      },
      {
        question: "Có bắt buộc phải dùng Tailscale không?",
        answer:
          "Không bắt buộc. Bạn có thể chạy trên localhost (127.0.0.1) hoặc đặt sau reverse proxy có TLS riêng. Tuy nhiên Tailscale là cách đơn giản nhất để dùng trên điện thoại khi ra ngoài mà không cần mở port hay quản lý chứng chỉ thủ công.",
      },
      {
        question: "Tại sao bản web yêu cầu HTTPS?",
        answer:
          "Bản Flutter Web chạy các module Rust WASM cần SharedArrayBuffer và cross-origin isolation (COOP/COEP), mà trình duyệt chỉ bật trên HTTPS hoặc 127.0.0.1. Truy cập qua HTTP thường như http://100.x.y.z sẽ không chạy được; hãy đặt sau tailscale serve hoặc reverse proxy HTTPS.",
      },
      {
        question: "Nếu mở Zalo Web ở trình duyệt khác thì chuyện gì xảy ra?",
        answer:
          "Zalo chỉ cho phép một phiên web duy nhất cho mỗi tài khoản, nên phiên trên server zalos sẽ tạm thời bị ngắt. Khi bạn đóng tab Zalo Web kia, server sẽ chờ hết khoảng trễ rồi tự kết nối lại.",
      },
      {
        question: "Tài khoản Zalo có bị khoá không?",
        answer:
          "Không. Với phía Zalo, zalos hoạt động như một phiên Zalo Web bình thường, tương đương việc bạn mở chat.zalo.me trên trình duyệt. Server gom toàn bộ thao tác từ các thiết bị vào phiên duy nhất đó và giãn cách các request đi ra tối thiểu 300 ms.",
      },
      {
        question: "Hỗ trợ những nền tảng nào?",
        answer:
          "Client Flutter hỗ trợ iOS, Android, macOS, Windows, Linux và trình duyệt web. Server chạy trên Bun + SQLite, đóng gói sẵn Docker image và kèm theo systemd unit nếu muốn chạy trực tiếp trên Linux.",
      },
    ],
  },
  cta: {
    title: "Tự chạy trên máy chủ của bạn",
    body: "Toàn bộ mã nguồn server, crate Rust và app Flutter đều mở trên GitHub. Clone repo, dựng Docker và bắt đầu với một thiết bị admin.",
    primary: "Xem hướng dẫn cài đặt",
    secondary: "Mở GitHub",
  },
  footer: {
    description:
      "Proxy Zalo tự host và ứng dụng Flutter đa nền tảng cho nhiều thiết bị, nhiều tài khoản.",
    navLabel: "Tài liệu và mã nguồn",
    github: "GitHub",
    onboardingVi: "Hướng dẫn (Tiếng Việt)",
    onboardingEn: "Hướng dẫn (English)",
    security: "Kiến trúc bảo mật",
    disclaimer:
      "zalos là dự án mã nguồn mở độc lập, không liên kết và không được Zalo hay VNG xác nhận hoặc bảo trợ.",
  },
}

export type SiteCopy = typeof vi

const en: SiteCopy = {
  links,
  nav: {
    skipToContent: "Skip to content",
    ariaLabel: "Primary navigation",
    features: "Features",
    howItWorks: "How it works",
    security: "Security",
    quickStart: "Setup",
    faq: "FAQ",
    github: "GitHub",
    openMenu: "Open menu",
    mobileMenuTitle: "Menu",
  },
  controls: {
    languageLabel: "Language",
    themeToggle: "Switch color theme",
    githubLabel: "zalos source code on GitHub",
  },
  hero: {
    badge: "Self-hosted Zalo proxy · Open source",
    title: "Use Zalo across multiple devices via your own server",
    subtitle:
      "Zalo limits you to one phone and one desktop, with no Linux app. zalos keeps the session on your own server and syncs messages, calls, and history to all your devices, across personal accounts and Zalo Official Accounts.",
    primaryCta: "Setup guide",
    secondaryCta: "Source on GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "zalos chat interface showing a product team group synced across 3 devices.",
      groupName: "Product Team",
      devices: "Synced · 3 devices",
      pinned: "Pinned: v2.4 release checklist",
      composerPlaceholder: "Message...",
      messages: [
        {
          side: "in",
          text: "Pushed the checkout fix to staging",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Got it, testing the QR payment flow now",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Check orders with promo codes too, totals were off yesterday",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Numbers match now. Good to ship at 2pm?",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "Yep, I'll drop the release notes in here first",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Features",
    title: "Core features",
    intro:
      "Personal chats, work groups, calls, and Official Accounts. Every client talks only to your server, which relays traffic to Zalo.",
    items: [
      {
        title: "Multiple accounts & access control",
        description:
          "Run personal Zalo accounts alongside Official Accounts in one app. Devices get admin or member roles, with per-account ACLs and instant revocation.",
        badge: null,
      },
      {
        title: "Multi-device sync",
        description:
          "Messages, read receipts, reactions, and typing indicators stay in sync across phone, tablet, desktop (including Linux), and web.",
        badge: null,
      },
      {
        title: "Light on device storage",
        description:
          "Chat history and media stay in SQLite on your server, and clients only fetch what you open. Zalo stops eating up gigabytes of phone storage.",
        badge: null,
      },
      {
        title: "Messaging & media",
        description:
          "1:1 and group chat with quotes, @mentions, formatting, urgency tags, recall, self-destruct timers, files up to 100 MiB, voice notes, stickers, and search.",
        badge: null,
      },
      {
        title: "Group board & productivity",
        description:
          "Pinned messages in both DMs and groups, a group board, polls (multi-choice and anonymous), shared notes, and one-time or recurring reminders.",
        badge: null,
      },
      {
        title: "1:1 voice & video calls",
        description:
          "Call regular Zalo users from any client via the server's ZRTC-to-WebRTC bridge. Every paired device rings together; whichever answers takes the call.",
        badge: null,
      },
      {
        title: "Contacts & QR scanner",
        description:
          "Find users by phone number, manage friend requests, set aliases, block contacts, and scan both Zalo QR codes and zalos pairing codes.",
        badge: null,
      },
      {
        title: "Conversation organization",
        description:
          "Pin or mute chats, assign color labels, archive threads, hide conversations behind a PIN, and set per-chat auto-delete timers.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "How it works",
    title: "How setup and sync work",
    intro:
      "Clients never talk to Zalo directly. Your server maintains one Zalo Web session per account, spaces outbound requests out, writes events to SQLite, and broadcasts updates to paired devices.",
    steps: [
      {
        title: "Start the server container",
        description:
          "Bring up the Docker Compose stack on a VPS, NAS, or home server. The image bundles the Flutter web client on the same port.",
      },
      {
        title: "Pair your devices",
        description:
          "Run zalos pair to generate a single-use URI or QR code. The first device is admin; later member devices start with no account access until granted.",
      },
      {
        title: "Sign in to Zalo",
        description:
          "Scan the QR code from your phone's Zalo app, or add a Zalo Official Account under Me → Accounts, and the server starts syncing conversations.",
      },
    ],
    architectureTitle: "Connection path",
    architecture: {
      clients: "Flutter clients",
      transport: "WebSocket + Noise IKpsk2",
      server: "zalos server (Bun + SQLite)",
      zalo: "Zalo Web / OA API",
    },
  },
  security: {
    eyebrow: "Security",
    title: "Rust crypto, keys on your devices",
    intro:
      "All cryptography lives in two Rust crates (zalos-noise and zalos-vault), never reimplemented in TypeScript or Dart. If a server disk or SQLite backup leaks, sealed message bodies and cached media remain unreadable.",
    points: [
      {
        title: "Mutually authenticated Noise transport",
        chip: "Noise_IKpsk2_25519",
        description:
          "Every WebSocket runs Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s, bound to its route prologue and pinned to the server's static key from pairing.",
      },
      {
        title: "Client-held HPKE vault",
        chip: "HPKE · RFC 9180",
        description:
          "Message bodies and cached media are sealed at rest with a client-derived public key. The 32-byte vault root never leaves your devices and supports versioned key rotation.",
      },
      {
        title: "Single-use pairing & per-account ACLs",
        chip: "RBAC · 10m TTL",
        description:
          "Pairing tokens expire in 10 minutes and work once. Each device gets its own PSK, starts with an empty member ACL, and can be revoked live.",
      },
      {
        title: "Hardened container defaults",
        chip: "non-root · ro-fs",
        description:
          "Runs non-root on a read-only root filesystem with dropped Linux capabilities and startup hardening checks via zalos doctor.",
      },
      {
        title: "DNS-pinned SSRF guard",
        chip: "DNS-pinned SSRF",
        description:
          "Media fetches pin resolved IPs at connect time to block DNS rebinding and HTTPS downgrades, with an optional strict Zalo/CDN egress allowlist.",
      },
      {
        title: "Private over your tailnet",
        chip: "Tailscale · tailnet",
        description:
          "Ships with a Tailscale sidecar setup so no ports are exposed to the public internet. Use tailscale serve for HTTPS when accessing the web client.",
      },
    ],
    linkLabel: "Read SECURITY_ARCHITECT.md",
  },
  quickStart: {
    eyebrow: "Setup",
    title: "Deploy the server",
    intro:
      "Use Docker + Tailscale for daily access across devices, local mode to test on loopback, or build the Flutter client directly. The first Docker build takes a few minutes while it compiles Rust WASM and Flutter Web.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Local mode",
      client: "Flutter client",
    },
    copy: "Copy",
    copied: "Copied",
    copyLabel: "Copy commands",
    scrollLabel: "Scroll horizontally to view full commands",
    note: "For environment setup, NAS deployment, and troubleshooting, see the",
    noteLink: "onboarding guide",
  },
  faq: {
    eyebrow: "FAQ",
    title: "Frequently asked questions",
    intro:
      "A few details on storage, networking, and how the Zalo Web session behaves before you deploy.",
    items: [
      {
        question: "Is zalos affiliated with Zalo?",
        answer:
          "No. It is an independent open-source project with no affiliation with Zalo or VNG. Personal accounts connect as a regular Zalo Web session; Official Accounts use Zalo's OA OpenAPI.",
      },
      {
        question: "Where is data stored, and can the server read it?",
        answer:
          "Everything stays on the server you host, with no third-party relay. Message bodies and cached media are sealed at rest using HPKE with keys held on your devices, so the server cannot decrypt stored history. Operational metadata (thread IDs, timestamps, senders, unread counts) remains clear for routing and sync.",
      },
      {
        question: "Do I have to use Tailscale?",
        answer:
          "No. You can run on localhost (127.0.0.1) or behind any TLS reverse proxy you already manage. Tailscale is just the easiest way to reach your server from mobile devices without opening firewall ports.",
      },
      {
        question: "Why does the web client require HTTPS?",
        answer:
          "The Flutter web client uses Rust WASM modules that rely on SharedArrayBuffer and cross-origin isolation (COOP/COEP), which browsers only allow on HTTPS or 127.0.0.1. Plain HTTP over a LAN or tailnet IP will not work; put it behind tailscale serve or a TLS proxy.",
      },
      {
        question: "What happens if I open Zalo Web in another browser?",
        answer:
          "Zalo only permits one active web session per account, so opening Zalo Web elsewhere temporarily disconnects zalos. Once you close that other tab, the server waits out a cooldown and reconnects automatically.",
      },
      {
        question: "Could my Zalo account get locked?",
        answer:
          "No. To Zalo, zalos looks like a regular Zalo Web session, the same as keeping chat.zalo.me open in a browser. The server funnels all device actions through that single session and spaces outbound requests at least 300 ms apart.",
      },
      {
        question: "Which platforms are supported?",
        answer:
          "The Flutter client builds for iOS, Android, macOS, Windows, Linux, and Web. The Bun + SQLite server ships as a Docker image, with a systemd unit included if you prefer running directly on Linux.",
      },
    ],
  },
  cta: {
    title: "Run it on your own hardware",
    body: "The server, Rust crypto crates, and Flutter client are all open source on GitHub. Clone the repo, bring up Docker, and pair your first admin device.",
    primary: "Jump to setup",
    secondary: "Open GitHub",
  },
  footer: {
    description:
      "Self-hosted Zalo proxy and cross-platform Flutter client for multi-device, multi-account use.",
    navLabel: "Docs and source",
    github: "GitHub",
    onboardingVi: "Onboarding (Vietnamese)",
    onboardingEn: "Onboarding (English)",
    security: "Security architecture",
    disclaimer:
      "zalos is an independent open-source project and is not affiliated with, endorsed by, or sponsored by Zalo or VNG.",
  },
}

export const site = {
  vi,
  en,
}
