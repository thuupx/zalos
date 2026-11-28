import type { Metadata, Viewport } from "next";
import { Geist_Mono } from "next/font/google";
import localFont from "next/font/local";

import { Providers } from "@/components/site/providers";

import "./globals.css";

const googleSansFlex = localFont({
  src: "../fonts/GoogleSansFlex.ttf",
  variable: "--font-sans",
  weight: "100 1000",
  display: "swap",
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  metadataBase: new URL(
    process.env.NEXT_PUBLIC_SITE_URL ?? "http://localhost:3000"
  ),
  title: "zalos · Proxy Zalo tự host cho nhiều thiết bị",
  description:
    "Proxy Zalo tự host và ứng dụng Flutter cho iOS, Android, macOS, Windows, Linux và Web. Hỗ trợ nhiều thiết bị, nhiều tài khoản cá nhân lẫn Zalo OA.",
  openGraph: {
    title: "zalos · Proxy Zalo tự host cho nhiều thiết bị",
    description:
      "Proxy Zalo tự host cho nhiều thiết bị và nhiều tài khoản, kèm mã hoá Noise và HPKE.",
    siteName: "zalos",
    locale: "vi_VN",
    type: "website",
    images: [
      {
        url: "/brand/zalos-icon-512.png",
        width: 512,
        height: 512,
        alt: "zalos",
      },
    ],
  },
};

export const viewport: Viewport = {
  themeColor: [
    { media: "(prefers-color-scheme: light)", color: "#8e3524" },
    { media: "(prefers-color-scheme: dark)", color: "#0c0a0a" },
  ],
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="vi"
      suppressHydrationWarning
      className={`${googleSansFlex.variable} ${geistMono.variable} h-full antialiased`}
    >
      <body className="min-h-full bg-background text-foreground">
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
