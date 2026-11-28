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
    skipToContent: "Bỏ qua, tới nội dung chính",
    ariaLabel: "Menu chính",
    features: "Tính năng",
    howItWorks: "Cách chạy",
    security: "Bảo mật",
    quickStart: "Bắt đầu",
    faq: "Hỏi đáp",
    github: "GitHub",
    openMenu: "Mở menu",
    mobileMenuTitle: "Menu",
  },
  controls: {
    languageLabel: "Đổi ngôn ngữ",
    themeToggle: "Đổi giao diện sáng/tối",
    githubLabel: "Xem source zalos trên GitHub",
  },
  hero: {
    badge: "Self-host · Nhiều thiết bị · Nhiều tài khoản",
    title: "Một tài khoản Zalo, xài trên mọi thiết bị.",
    subtitle:
      "zalos là server Zalo bạn tự host. Login Zalo một lần trên server, rồi dùng cùng lúc trên điện thoại, máy tính, iPad hay trình duyệt. Có cả Zalo OA luôn.",
    primaryCta: "Tự host ngay",
    secondaryCta: "Xem source trên GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "Giao diện chat của zalos: một nhóm đang nhắn tin, tin nhắn sync qua nhiều thiết bị.",
      groupName: "Team zalos",
      devices: "3 thiết bị đang online",
      pinned: "Ghim: checklist deploy lên NAS",
      composerPlaceholder: "Nhập tin nhắn...",
      messages: [
        {
          side: "in",
          text: "Deploy lên NAS xong rồi nha",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Ngon, để mình login trên iPad thử",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Tin nhắn sync qua điện thoại luôn rồi đó",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Thấy rồi, seen bên máy tính cũng khớp luôn",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "Thêm máy mới thì tạo mã pair mới nha, mã cũ hết hạn rồi",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Tính năng",
    title: "zalos làm được gì",
    intro:
      "Gần như mọi thứ bạn hay dùng trên Zalo, giờ chạy qua server của chính bạn.",
    items: [
      {
        title: "Nhiều tài khoản",
        description:
          "Tài khoản cá nhân và Zalo OA nằm chung một app, chuyển qua lại một chạm.",
        badge: null,
      },
      {
        title: "Sync mọi thiết bị",
        description:
          "Tin nhắn, seen, reaction, trạng thái đang gõ đều sync ngay giữa điện thoại, máy tính và web.",
        badge: null,
      },
      {
        title: "Nhẹ máy",
        description:
          "Lịch sử chat và media nằm trên server, máy chỉ tải khi cần xem. Khỏi lo Zalo ngốn bộ nhớ điện thoại nữa.",
        badge: null,
      },
      {
        title: "Nhắn tin, gửi file",
        description:
          "Chat 1:1 và nhóm, reply, tag tên, thu hồi, tin nhắn tự huỷ, gửi file tới 100 MiB, tin nhắn thoại, sticker, tìm lại tin cũ.",
        badge: null,
      },
      {
        title: "Làm việc nhóm",
        description:
          "Ghim tin, bảng tin, bình chọn, ghi chú, nhắc hẹn. Team chạy việc trong nhóm Zalo vẫn đủ đồ nghề.",
        badge: null,
      },
      {
        title: "Gọi thoại, gọi video",
        description:
          "Gọi 1:1 với người dùng Zalo như bình thường. Máy nào của bạn cũng đổ chuông, máy nào bắt trước thì nghe.",
        badge: null,
      },
      {
        title: "Danh bạ và QR",
        description:
          "Tìm bạn qua số điện thoại, kết bạn, chặn, quét QR y như app Zalo.",
        badge: null,
      },
      {
        title: "Gọn gàng hội thoại",
        description:
          "Ghim, tắt thông báo, gắn nhãn màu, lưu trữ, ẩn hội thoại bằng mã PIN, hẹn giờ tự xoá tin.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "Cách chạy",
    title: "Ba bước là dùng được",
    intro:
      "Server, thiết bị, phiên đăng nhập đều nằm trong tay bạn. zalos chỉ lo chuyển tin và sync.",
    steps: [
      {
        title: "Dựng server bằng Docker",
        description:
          "Chạy docker compose là có server. Image có sẵn luôn bản web, khỏi build riêng.",
      },
      {
        title: "Pair thiết bị",
        description:
          "Server tạo mã pair dùng một lần. Quét QR hoặc dán mã vào app là vào được.",
      },
      {
        title: "Login Zalo bằng QR",
        description:
          "Mở Zalo trên điện thoại, quét QR là server bắt đầu sync tin nhắn về.",
      },
    ],
    architectureTitle: "Dữ liệu đi như thế nào",
    architecture: {
      clients: "App zalos",
      transport: "WebSocket + Noise",
      server: "Server của bạn",
      zalo: "Zalo",
    },
  },
  security: {
    eyebrow: "Bảo mật",
    title: "Server của bạn, key của bạn",
    intro:
      "Không có server trung gian nào hết. Dữ liệu nằm trên máy bạn và được mã hoá kỹ.",
    points: [
      {
        title: "Kết nối bằng Noise",
        chip: "IKpsk2_25519_ChaChaPoly_BLAKE2s",
        description:
          "Mỗi kết nối là một phiên Noise xác thực hai chiều. App ghim key của server nên không ai giả mạo được.",
      },
      {
        title: "Mã hoá dữ liệu lưu trữ",
        chip: "HPKE / RFC 9180",
        description:
          "Tin nhắn và media trên server được mã hoá bằng HPKE. Key nằm trên thiết bị của bạn, server không tự đọc được.",
      },
      {
        title: "Mã pair dùng một lần",
        chip: "10 phút",
        description: "Mỗi mã chỉ dùng được một lần và tự hết hạn sau 10 phút.",
      },
      {
        title: "Container quyền tối thiểu",
        chip: "non-root",
        description:
          "Chạy bằng user thường, filesystem read-only, bỏ hết capability không cần thiết.",
      },
      {
        title: "Chặn SSRF",
        chip: "SSRF guard",
        description:
          "Request tải media nào cũng được kiểm tra địa chỉ trước khi đi ra ngoài.",
      },
      {
        title: "Chạy riêng trong tailnet",
        chip: "Tailscale",
        description:
          "Thiết kế để chạy trong mạng Tailscale riêng, không cần mở port ra internet.",
      },
    ],
    linkLabel: "Đọc chi tiết kiến trúc bảo mật",
  },
  quickStart: {
    eyebrow: "Bắt đầu",
    title: "Chọn cách chạy",
    intro:
      "Chạy thật thì dùng Docker + Tailscale. Chỉ thử trên máy thì chạy local, hoặc build thẳng app Flutter.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Local",
      client: "App",
    },
    copy: "Copy",
    copied: "Đã copy",
    copyLabel: "Copy lệnh",
    scrollLabel: "Khối lệnh, kéo ngang để xem hết",
    note: "Cần hướng dẫn chi tiết hơn?",
    noteLink: "Xem tài liệu onboarding.",
  },
  faq: {
    eyebrow: "Hỏi đáp",
    title: "Vài điều nên biết trước",
    intro: "Nói trước luôn mấy giới hạn để bạn khỏi bất ngờ.",
    items: [
      {
        question: "zalos có phải app chính thức của Zalo không?",
        answer:
          "Không. zalos là dự án độc lập, không liên quan gì tới Zalo hay VNG. App dùng giao thức Zalo Web không chính thức.",
      },
      {
        question: "Dữ liệu của mình nằm ở đâu?",
        answer:
          "Trên server bạn tự host, không đi qua bên thứ ba nào. Nội dung tin nhắn và media được mã hoá, key nằm trên thiết bị của bạn.",
      },
      {
        question: "Có bắt buộc dùng Tailscale không?",
        answer:
          "Không bắt buộc, chạy local cũng được. Nhưng muốn dùng khi ra ngoài thì Tailscale là cách gọn và an toàn nhất, khỏi mở port.",
      },
      {
        question: "Sao bản web cần HTTPS?",
        answer:
          "Trình duyệt chỉ cho chạy phần mã hoá khi trang mở qua HTTPS. Dùng tailscale serve là có HTTPS ngay, một lệnh là xong.",
      },
      {
        question: "Mở Zalo Web ở chỗ khác thì sao?",
        answer:
          "Zalo chỉ cho một phiên web mỗi tài khoản, nên zalos sẽ tạm bị đẩy ra. Đóng Zalo Web bên kia là zalos tự kết nối lại.",
      },
      {
        question: "Tài khoản có bị khoá không?",
        answer:
          "Không. Với Zalo, zalos chỉ là một phiên Zalo Web bình thường, giống hệt bạn mở chat.zalo.me trên trình duyệt.",
      },
      {
        question: "Chạy được trên những nền tảng nào?",
        answer:
          "App có bản iOS, Android, macOS, Windows, Linux và web. Server chạy bằng Docker.",
      },
    ],
  },
  cta: {
    title: "Tự host zalos thử nhé?",
    body: "Dựng server, pair thiết bị, quét QR login Zalo là dùng được.",
    primary: "Bắt đầu",
    secondary: "Xem trên GitHub",
  },
  footer: {
    description: "Server Zalo tự host, dùng nhiều thiết bị, nhiều tài khoản.",
    navLabel: "Liên kết",
    github: "GitHub",
    onboardingVi: "Onboarding (tiếng Việt)",
    onboardingEn: "Onboarding (English)",
    security: "Kiến trúc bảo mật",
    disclaimer:
      "zalos là dự án độc lập, không liên kết và không được Zalo hay VNG bảo trợ.",
  },
}

export type SiteCopy = typeof vi

const en: SiteCopy = {
  links,
  nav: {
    skipToContent: "Skip to content",
    ariaLabel: "Main menu",
    features: "Features",
    howItWorks: "How it works",
    security: "Security",
    quickStart: "Get started",
    faq: "FAQ",
    github: "GitHub",
    openMenu: "Open menu",
    mobileMenuTitle: "Menu",
  },
  controls: {
    languageLabel: "Change language",
    themeToggle: "Toggle light/dark mode",
    githubLabel: "View the zalos source on GitHub",
  },
  hero: {
    badge: "Self-hosted · Many devices · Many accounts",
    title: "One Zalo account, on every device you own.",
    subtitle:
      "zalos is a Zalo server you host yourself. Log in to Zalo once on the server, then use it from your phone, laptop, iPad and browser at the same time. Zalo Official Accounts work too.",
    primaryCta: "Host it yourself",
    secondaryCta: "View source on GitHub",
    platforms: ["iOS", "Android", "macOS", "Windows", "Linux", "Web"],
    mockup: {
      caption:
        "The zalos chat screen: a group chatting, messages synced across devices.",
      groupName: "zalos team",
      devices: "3 devices online",
      pinned: "Pinned: NAS deploy checklist",
      composerPlaceholder: "Type a message...",
      messages: [
        {
          side: "in",
          text: "NAS deploy is done",
          time: "09:41",
          reaction: null,
        },
        {
          side: "out",
          text: "Nice, logging in on my iPad now",
          time: "09:42",
          reaction: "2",
        },
        {
          side: "in",
          text: "Messages already showed up on my phone",
          time: "09:43",
          reaction: null,
        },
        {
          side: "out",
          text: "Same here, read receipts match on my laptop too",
          time: "09:44",
          reaction: null,
        },
        {
          side: "in",
          text: "New device? Make a fresh pairing code, the old one expired",
          time: "09:45",
          reaction: null,
        },
      ],
    },
  },
  features: {
    eyebrow: "Features",
    title: "What zalos does",
    intro:
      "Most of what you use Zalo for every day, running through your own server.",
    items: [
      {
        title: "Many accounts",
        description:
          "Personal accounts and Zalo Official Accounts in one app. Switch with a tap.",
        badge: null,
      },
      {
        title: "Sync across devices",
        description:
          "Messages, read receipts, reactions and typing sync right away between phone, desktop and web.",
        badge: null,
      },
      {
        title: "Light on storage",
        description:
          "Chat history and media live on the server, and devices only download what you open. No more Zalo eating up your phone's storage.",
        badge: null,
      },
      {
        title: "Chat and files",
        description:
          "1:1 and group chat, replies, mentions, recall, self-destructing messages, files up to 100 MiB, voice messages, stickers, message search.",
        badge: null,
      },
      {
        title: "Group tools",
        description:
          "Pinned messages, group board, polls, notes and reminders. Everything a team needs inside a Zalo group.",
        badge: null,
      },
      {
        title: "Voice and video calls",
        description:
          "1:1 calls with regular Zalo users. All your devices ring, and whichever picks up first takes the call.",
        badge: null,
      },
      {
        title: "Contacts and QR",
        description:
          "Find people by phone number, add friends, block, and scan QR codes like in the Zalo app.",
        badge: null,
      },
      {
        title: "Tidy conversations",
        description:
          "Pin, mute, color labels, archive, hide conversations behind a PIN, and auto-delete timers.",
        badge: null,
      },
    ],
  },
  howItWorks: {
    eyebrow: "How it works",
    title: "Three steps and you're in",
    intro:
      "You own the server, the devices and the login session. zalos just moves messages and keeps everything in sync.",
    steps: [
      {
        title: "Run the server with Docker",
        description:
          "One docker compose command. The image ships the web app too, no separate build.",
      },
      {
        title: "Pair your devices",
        description:
          "The server gives you a one-time pairing code. Scan the QR or paste the code into the app.",
      },
      {
        title: "Log in to Zalo with QR",
        description:
          "Scan the QR with Zalo on your phone and the server starts syncing your messages.",
      },
    ],
    architectureTitle: "How your data flows",
    architecture: {
      clients: "zalos apps",
      transport: "WebSocket + Noise",
      server: "Your server",
      zalo: "Zalo",
    },
  },
  security: {
    eyebrow: "Security",
    title: "Your server, your keys",
    intro:
      "There is no middleman server. Your data stays on your machine, and it is encrypted.",
    points: [
      {
        title: "Noise connections",
        chip: "IKpsk2_25519_ChaChaPoly_BLAKE2s",
        description:
          "Every connection is a mutually authenticated Noise session. Apps pin the server key, so nobody can impersonate it.",
      },
      {
        title: "Encrypted storage",
        chip: "HPKE / RFC 9180",
        description:
          "Messages and media on the server are encrypted with HPKE. The keys live on your devices, so the server can't read them on its own.",
      },
      {
        title: "One-time pairing codes",
        chip: "10 minutes",
        description: "Each code works once and expires after 10 minutes.",
      },
      {
        title: "Locked-down container",
        chip: "non-root",
        description:
          "Runs as a regular user on a read-only filesystem with every unneeded capability dropped.",
      },
      {
        title: "SSRF protection",
        chip: "SSRF guard",
        description:
          "Every media download is checked against its resolved address before it leaves the server.",
      },
      {
        title: "Private on your tailnet",
        chip: "Tailscale",
        description:
          "Built to live on your own Tailscale network. No ports open to the internet.",
      },
    ],
    linkLabel: "Read the security architecture",
  },
  quickStart: {
    eyebrow: "Get started",
    title: "Pick how you want to run it",
    intro:
      "For real use, go with Docker + Tailscale. Just trying it out? Run it locally, or build the Flutter app directly.",
    tabs: {
      docker: "Docker + Tailscale",
      local: "Local",
      client: "App",
    },
    copy: "Copy",
    copied: "Copied",
    copyLabel: "Copy commands",
    scrollLabel: "Commands, scroll sideways to see all",
    note: "Need more detail?",
    noteLink: "Read the onboarding guide.",
  },
  faq: {
    eyebrow: "FAQ",
    title: "Good to know first",
    intro: "The limits, up front, so nothing surprises you later.",
    items: [
      {
        question: "Is zalos an official Zalo app?",
        answer:
          "No. zalos is an independent project with no ties to Zalo or VNG. It uses Zalo's unofficial web protocol.",
      },
      {
        question: "Where does my data live?",
        answer:
          "On the server you host. Nothing goes through a third party. Message content and media are encrypted, and the keys stay on your devices.",
      },
      {
        question: "Do I have to use Tailscale?",
        answer:
          "No, you can run it locally. But if you want to use it away from home, Tailscale is the simplest safe option, with no ports to open.",
      },
      {
        question: "Why does the web app need HTTPS?",
        answer:
          "Browsers only allow the encryption the web app relies on over HTTPS. tailscale serve gives you HTTPS with one command.",
      },
      {
        question: "What if I open Zalo Web somewhere else?",
        answer:
          "Zalo allows one web session per account, so zalos gets bumped for a while. Close the other Zalo Web tab and zalos reconnects on its own.",
      },
      {
        question: "Can my account get locked?",
        answer:
          "No. To Zalo, zalos is just a regular Zalo Web session, the same as opening chat.zalo.me in your browser.",
      },
      {
        question: "Which platforms are supported?",
        answer:
          "The app runs on iOS, Android, macOS, Windows, Linux and the web. The server runs in Docker.",
      },
    ],
  },
  cta: {
    title: "Give self-hosting zalos a try?",
    body: "Start the server, pair a device, scan the QR to log in to Zalo, done.",
    primary: "Get started",
    secondary: "View on GitHub",
  },
  footer: {
    description: "A self-hosted Zalo server for many devices and many accounts.",
    navLabel: "Links",
    github: "GitHub",
    onboardingVi: "Onboarding (Vietnamese)",
    onboardingEn: "Onboarding (English)",
    security: "Security architecture",
    disclaimer:
      "zalos is an independent project. It is not affiliated with, endorsed by or sponsored by Zalo or VNG.",
  },
}

export const site = {
  vi,
  en,
}
