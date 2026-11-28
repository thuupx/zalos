const vi = {
  links: {
    repo: "https://github.com/thuupx/zalos",
    onboardingVi:
      "https://github.com/thuupx/zalos/blob/main/docs/onboarding/vi/README.md",
    onboardingEn:
      "https://github.com/thuupx/zalos/blob/main/docs/onboarding/en/README.md",
    security:
      "https://github.com/thuupx/zalos/blob/main/docs/SECURITY_ARCHITECT.md",
  },
  nav: {
    skipToContent: "Bỏ qua đến nội dung",
    ariaLabel: "Điều hướng chính",
    features: "Tính năng",
    howItWorks: "Cách hoạt động",
    security: "Bảo mật",
    quickStart: "Bắt đầu nhanh",
    faq: "Hỏi đáp",
    github: "GitHub",
    openMenu: "Mở menu điều hướng",
    mobileMenuTitle: "Điều hướng",
  },
  controls: {
    languageLabel: "Chọn ngôn ngữ",
    themeToggle: "Chuyển giao diện sáng hoặc tối",
    githubLabel: "Mở kho mã nguồn zalos trên GitHub",
  },
  hero: {
    badge: "Tự host · Đa thiết bị · Đa tài khoản",
    title: "Một tài khoản Zalo, trên mọi thiết bị của bạn.",
    subtitle:
      "zalos là proxy Zalo tự host cùng ứng dụng Flutter cho mọi nền tảng. Chạy máy chủ của riêng bạn, ghép nối các thiết bị tin cậy và dùng tài khoản cá nhân lẫn Zalo OA trong một ứng dụng.",
    primaryCta: "Bắt đầu tự host",
    secondaryCta: "Xem trên GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "Mô phỏng giao diện trò chuyện zalos với tin nhắn được đồng bộ trên nhiều thiết bị.",
      groupName: "Nhóm vận hành",
      devices: "3 thiết bị đang kết nối",
      pinned: "Ghim: Kiểm tra bản triển khai máy chủ",
      composerPlaceholder: "Nhắn gì đó...",
      messages: [
        {
          side: "in",
          text: "Mình vừa ghim lại các bước triển khai nhé.",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Cảm ơn, mình sẽ kiểm tra trên cả điện thoại và máy tính.",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Tin nhắn đã đồng bộ trên các thiết bị.",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Đúng rồi, trạng thái đã đọc cũng khớp nhau.",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "Nhớ dùng mã ghép nối một lần khi thêm thiết bị mới.",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Tính năng",
    title: "Đầy đủ cho Zalo cá nhân và OA",
    intro:
      "Một máy chủ do bạn kiểm soát, nhiều tài khoản trong một ứng dụng và trạng thái trò chuyện nhất quán trên mọi thiết bị.",
    items: [
      {
        title: "Nhiều tài khoản",
        description:
          "Dùng tài khoản Zalo cá nhân và Zalo Official Accounts trong cùng một ứng dụng, thông qua máy chủ do bạn vận hành.",
        badge: null,
      },
      {
        title: "Đồng bộ đa thiết bị",
        description:
          "Tin nhắn, trạng thái đã đọc, cảm xúc, trạng thái nhập và trạng thái hội thoại được đồng bộ giữa các thiết bị.",
        badge: null,
      },
      {
        title: "Tin nhắn và media",
        description:
          "Trò chuyện 1:1 và nhóm, trả lời, trích dẫn, nhắc tên, chuyển tiếp, thu hồi, tin nhắn tự hủy, media đến 100 MiB, tin nhắn thoại, sticker, xem trước liên kết và tìm kiếm trong hội thoại.",
        badge: null,
      },
      {
        title: "Công cụ cho nhóm",
        description:
          "Ghim tin nhắn, bảng tin nhóm, bình chọn, ghi chú và nhắc hẹn ngay trong hội thoại.",
        badge: null,
      },
      {
        title: "Cuộc gọi thoại và video",
        description:
          "Gọi thoại và video 1:1 với người dùng Zalo từ mọi client zalos, đổ chuông trên mọi thiết bị, tắt mic, giữ máy và đổi camera.",
        badge: null,
      },
      {
        title: "Danh bạ và QR",
        description:
          "Tìm theo số điện thoại, gửi và nhận lời mời kết bạn, chặn liên hệ và quét mã QR.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "Cách hoạt động",
    title: "Ba bước từ máy chủ trống đến phiên Zalo đồng bộ",
    intro:
      "Bạn kiểm soát máy chủ, thiết bị và phiên đăng nhập. zalos chỉ làm nhiệm vụ truyền tải và đồng bộ.",
    steps: [
      {
        title: "Triển khai máy chủ bằng Docker",
        description:
          "Chạy image Docker đã được tăng cường bảo mật. Image này cũng phục vụ web client.",
      },
      {
        title: "Ghép nối thiết bị",
        description:
          "Dùng mã một lần hoặc QR để thêm từng thiết bị, với quyền admin hoặc member rõ ràng.",
      },
      {
        title: "Đăng nhập Zalo bằng QR",
        description:
          "Quét QR bằng ứng dụng Zalo để bắt đầu phiên và đồng bộ hội thoại.",
      },
    ],
    architectureTitle: "Luồng kết nối",
    architecture: {
      clients: "Ứng dụng client",
      transport: "Noise qua WebSocket",
      server: "Máy chủ zalos của bạn",
      zalo: "Zalo",
    },
  },
  security: {
    eyebrow: "Bảo mật",
    title: "Thiết kế cho máy chủ riêng, khóa ở phía client",
    intro:
      "Mọi kết nối và dữ liệu lưu trữ đều được bảo vệ theo mô hình máy chủ do bạn kiểm soát.",
    points: [
      {
        title: "Kênh Noise ghim khóa máy chủ",
        chip: "IKpsk2_25519_ChaChaPoly_BLAKE2s",
        description:
          "Mỗi kết nối client đều là một phiên Noise được xác thực lẫn nhau và ghim với khóa tĩnh của máy chủ.",
      },
      {
        title: "Vault HPKE cho dữ liệu lưu trữ",
        chip: "HPKE / RFC 9180",
        description:
          "Tin nhắn và media được niêm phong khi lưu trữ bằng vault HPKE có khóa chỉ nằm trên client.",
      },
      {
        title: "Mã ghép nối một lần",
        chip: "10 phút",
        description:
          "Mỗi mã ghép nối chỉ dùng một lần và tự hết hạn sau 10 phút.",
      },
      {
        title: "Container hạn chế quyền",
        chip: "non-root",
        description:
          "Image Docker chạy với người dùng non-root và hệ thống tập tin chỉ đọc.",
      },
      {
        title: "Lấy media có chống SSRF",
        chip: "SSRF guard",
        description:
          "Các yêu cầu tải media đi qua lớp bảo vệ SSRF trước khi rời máy chủ.",
      },
      {
        title: "Riêng tư trên tailnet",
        chip: "Tailscale",
        description:
          "zalos được thiết kế để vận hành riêng tư trên một Tailscale tailnet của riêng bạn.",
      },
    ],
    linkLabel: "Đọc kiến trúc bảo mật",
  },
  quickStart: {
    eyebrow: "Bắt đầu nhanh",
    title: "Chạy zalos theo cách phù hợp với bạn",
    intro:
      "Docker với Tailscale là lựa chọn phù hợp cho một tailnet riêng. Bạn cũng có thể chạy local hoặc khởi động client Flutter trực tiếp.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Local",
      client: "Client",
    },
    copy: "Sao chép",
    copied: "Đã sao chép",
    copyLabel: "Sao chép đoạn lệnh",
    scrollLabel: "Đoạn lệnh có thể cuộn ngang",
    note: "Cần thêm chi tiết cấu hình và ghép nối?",
    noteLink: "Đọc hướng dẫn onboarding.",
  },
  faq: {
    eyebrow: "Hỏi đáp",
    title: "Những điều cần biết trước khi tự host",
    intro:
      "zalos là một cầu nối không chính thức. Phần này nói rõ cả giới hạn lẫn điểm mạnh.",
    items: [
      {
        question: "zalos có phải sản phẩm chính thức của Zalo không?",
        answer:
          "Không. zalos là một dự án độc lập, không liên kết hoặc được Zalo/VNG chứng thực. Dự án sử dụng giao thức web không chính thức của Zalo.",
      },
      {
        question: "Dữ liệu của tôi nằm ở đâu?",
        answer:
          "Dữ liệu nằm trên máy chủ do bạn vận hành; không có dịch vụ tập trung nào. Tin nhắn và media được niêm phong khi lưu trữ bằng vault HPKE, còn khóa nằm trên client.",
      },
      {
        question: "Tôi có bắt buộc phải dùng Tailscale không?",
        answer:
          "Không bắt buộc. Bạn có thể chạy local; còn khi dùng web client qua mạng riêng, zalos được thiết kế cho một Tailscale tailnet và cần HTTPS, ví dụ qua tailscale serve.",
      },
      {
        question: "Vì sao web client cần HTTPS?",
        answer:
          "Web client cần HTTPS để hoạt động đúng trên trình duyệt. Bạn có thể dùng tailscale serve hoặc một reverse proxy có TLS mà bạn kiểm soát.",
      },
      {
        question: "Nếu tôi mở Zalo Web ở nơi khác thì sao?",
        answer:
          "Zalo cho phép một phiên web cho mỗi tài khoản. Khi Zalo Web được mở ở nơi khác, listener của zalos sẽ tạm dừng và tự kết nối lại sau.",
      },
      {
        question: "Tài khoản Zalo của tôi có thể bị hạn chế không?",
        answer:
          "Có thể. Zalo có thể hạn chế tài khoản khi dùng giao thức không chính thức. Vì vậy zalos giữ tần suất yêu cầu gần với hành vi con người, nhưng không thể bảo đảm rủi ro này biến mất.",
      },
      {
        question: "zalos hỗ trợ những nền tảng nào?",
        answer:
          "Client Flutter chạy trên iOS, Android, macOS, Windows, Linux và Web. Server dùng Bun, TypeScript và SQLite, được phân phối dưới dạng image Docker.",
      },
    ],
  },
  cta: {
    title: "Sẵn sàng chạy zalos trên máy chủ của bạn?",
    body:
      "Triển khai bằng Docker, ghép nối thiết bị và quét QR đăng nhập Zalo. Không có dịch vụ tập trung nào ở giữa.",
    primary: "Bắt đầu nhanh",
    secondary: "Mở GitHub",
  },
  footer: {
    description:
      "Proxy Zalo tự host cho nhiều thiết bị và nhiều tài khoản.",
    navLabel: "Liên kết cuối trang",
    github: "GitHub",
    onboardingVi: "Onboarding tiếng Việt",
    onboardingEn: "Onboarding tiếng Anh",
    security: "Kiến trúc bảo mật",
    disclaimer:
      "zalos là một dự án độc lập và không liên kết, không được chứng thực hoặc tài trợ bởi Zalo hoặc VNG.",
  },
}

export type SiteCopy = typeof vi

const en: SiteCopy = {
  links: {
    repo: "https://github.com/thuupx/zalos",
    onboardingVi:
      "https://github.com/thuupx/zalos/blob/main/docs/onboarding/vi/README.md",
    onboardingEn:
      "https://github.com/thuupx/zalos/blob/main/docs/onboarding/en/README.md",
    security:
      "https://github.com/thuupx/zalos/blob/main/docs/SECURITY_ARCHITECT.md",
  },
  nav: {
    skipToContent: "Skip to content",
    ariaLabel: "Primary navigation",
    features: "Features",
    howItWorks: "How it works",
    security: "Security",
    quickStart: "Quick start",
    faq: "FAQ",
    github: "GitHub",
    openMenu: "Open navigation menu",
    mobileMenuTitle: "Navigation",
  },
  controls: {
    languageLabel: "Choose language",
    themeToggle: "Toggle light or dark theme",
    githubLabel: "Open the zalos repository on GitHub",
  },
  hero: {
    badge: "Self-hosted · Multi-device · Multi-account",
    title: "One Zalo account, on every device you own.",
    subtitle:
      "zalos is a self-hosted Zalo proxy with Flutter clients for every platform. Run your own server, pair the devices you trust, and use personal accounts and Zalo Official Accounts in one app.",
    primaryCta: "Start self-hosting",
    secondaryCta: "View on GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "A mockup of the zalos chat interface with messages synchronized across devices.",
      groupName: "Operations group",
      devices: "3 devices connected",
      pinned: "Pinned: Check the server deployment",
      composerPlaceholder: "Write a message...",
      messages: [
        {
          side: "in",
          text: "I pinned the deployment steps again.",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Thanks, I will check on both my phone and desktop.",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Messages are synchronized across the devices.",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Exactly, the read state matches too.",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "Remember to use a one-time pairing code for a new device.",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Features",
    title: "Complete for personal Zalo and OA",
    intro:
      "One server under your control, multiple accounts in one app, and consistent conversation state across your devices.",
    items: [
      {
        title: "Multi-account",
        description:
          "Use personal Zalo accounts and Zalo Official Accounts in the same app through a server you operate.",
        badge: null,
      },
      {
        title: "Multi-device sync",
        description:
          "Messages, read receipts, reactions, typing state, and conversation state stay synchronized between devices.",
        badge: null,
      },
      {
        title: "Messaging and media",
        description:
          "1:1 and group chat, replies, quotes, mentions, forward, recall, self-destruct messages, media up to 100 MiB, voice messages, stickers, link previews, and in-conversation search.",
        badge: null,
      },
      {
        title: "Group tools",
        description:
          "Pinned messages, the group board, polls, notes, and reminders right inside conversations.",
        badge: null,
      },
      {
        title: "Voice and video calls",
        description:
          "1:1 voice and video calls with Zalo users from any zalos client, ringing on every device, with mute, hold and camera switch.",
        badge: null,
      },
      {
        title: "Contacts and QR",
        description:
          "Search by phone number, send and receive friend requests, block contacts, and scan QR codes.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "How it works",
    title: "Three steps from an empty server to a synced Zalo session",
    intro:
      "You control the server, the devices, and the login session. zalos only handles transport and synchronization.",
    steps: [
      {
        title: "Deploy the server with Docker",
        description:
          "Run the hardened Docker image. The image also serves the web client.",
      },
      {
        title: "Pair your devices",
        description:
          "Use a one-time code or QR to add each device with explicit admin or member roles.",
      },
      {
        title: "Log in to Zalo with QR",
        description:
          "Scan the QR code with the Zalo app to start the session and synchronize conversations.",
      },
    ],
    architectureTitle: "Connection flow",
    architecture: {
      clients: "Client apps",
      transport: "Noise over WebSocket",
      server: "Your zalos server",
      zalo: "Zalo",
    },
  },
  security: {
    eyebrow: "Security",
    title: "Designed for a private server, with keys on the client",
    intro:
      "Connections and stored data are protected around a simple assumption: the server is yours.",
    points: [
      {
        title: "Noise channels pinned to the server",
        chip: "IKpsk2_25519_ChaChaPoly_BLAKE2s",
        description:
          "Every client connection is a mutually authenticated Noise session pinned to the server static key.",
      },
      {
        title: "HPKE vault for data at rest",
        chip: "HPKE / RFC 9180",
        description:
          "Messages and media are sealed at rest in an HPKE vault whose keys live only on clients.",
      },
      {
        title: "Single-use pairing codes",
        chip: "10 minutes",
        description:
          "Each pairing code can be used once and expires after 10 minutes.",
      },
      {
        title: "Least-privilege container",
        chip: "non-root",
        description:
          "The Docker image runs as a non-root user with a read-only file system.",
      },
      {
        title: "SSRF-guarded media fetching",
        chip: "SSRF guard",
        description:
          "Media download requests pass through SSRF protection before leaving the server.",
      },
      {
        title: "Private on a tailnet",
        chip: "Tailscale",
        description:
          "zalos is designed to run privately on your own Tailscale tailnet.",
      },
    ],
    linkLabel: "Read the security architecture",
  },
  quickStart: {
    eyebrow: "Quick start",
    title: "Run zalos the way that fits your setup",
    intro:
      "Docker with Tailscale fits a private tailnet. You can also run locally or start the Flutter client directly.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Local",
      client: "Client",
    },
    copy: "Copy",
    copied: "Copied",
    copyLabel: "Copy command block",
    scrollLabel: "Horizontally scrollable command block",
    note: "Need more configuration and pairing detail?",
    noteLink: "Read the onboarding guide.",
  },
  faq: {
    eyebrow: "FAQ",
    title: "What to know before self-hosting",
    intro:
      "zalos is an unofficial bridge. This section is clear about both limits and strengths.",
    items: [
      {
        question: "Is zalos an official Zalo product?",
        answer:
          "No. zalos is an independent project and is not affiliated with or endorsed by Zalo/VNG. It uses Zalo's unofficial web protocol.",
      },
      {
        question: "Where is my data stored?",
        answer:
          "Your data stays on the server you operate; there is no centralized service. Messages and media are sealed at rest with an HPKE vault whose keys live on clients.",
      },
      {
        question: "Do I have to use Tailscale?",
        answer:
          "No. You can run locally. When using the web client across a private network, zalos is designed for a Tailscale tailnet and needs HTTPS, for example through tailscale serve.",
      },
      {
        question: "Why does the web client need HTTPS?",
        answer:
          "The web client needs HTTPS to work correctly in the browser. You can use tailscale serve or a TLS reverse proxy that you control.",
      },
      {
        question: "What happens if I open Zalo Web somewhere else?",
        answer:
          "Zalo allows one web session per account. Opening Zalo Web elsewhere pauses the zalos listener, and zalos reconnects afterwards.",
      },
      {
        question: "Can my Zalo account be restricted?",
        answer:
          "Yes. Zalo can restrict accounts that use the unofficial protocol. zalos keeps request rates human-like, but that risk cannot be removed entirely.",
      },
      {
        question: "Which platforms does zalos support?",
        answer:
          "The Flutter client runs on iOS, Android, macOS, Windows, Linux, and Web. The server uses Bun, TypeScript, and SQLite, and ships as a Docker image.",
      },
    ],
  },
  cta: {
    title: "Ready to run zalos on your own server?",
    body:
      "Deploy with Docker, pair your devices, and scan the Zalo login QR code. No centralized service sits in between.",
    primary: "Start quick start",
    secondary: "Open GitHub",
  },
  footer: {
    description:
      "A self-hosted Zalo proxy for multiple devices and multiple accounts.",
    navLabel: "Footer links",
    github: "GitHub",
    onboardingVi: "Vietnamese onboarding",
    onboardingEn: "English onboarding",
    security: "Security architecture",
    disclaimer:
      "zalos is an independent project and is not affiliated with, endorsed by, or sponsored by Zalo or VNG.",
  },
}

export const site = {
  vi,
  en,
}
