// ZALOS_ZALO_MOCK_URL: point the real zca-js gateway at the offline Zalo
// mock (mock/, see mock/README.md). Only accepted together with --dev or
// --local; cli.ts enforces that.
//
// zca-js reaches Zalo over plain fetch (ctx.options.polyfill) to hosts
// under these zones; the listener ws url comes from the login info, so
// the mock controls it there directly.
const ZALO_HOST_RE = /\.(zalo\.me|zaloapp\.com|zadn\.vn|zdn\.vn)$/;
const ZALO_HOST_EXACT = new Set(["zalo.me", "zaloapp.com", "zadn.vn", "zdn.vn"]);

export function isZaloHost(hostname: string): boolean {
  const host = hostname.toLowerCase();
  return ZALO_HOST_EXACT.has(host) || ZALO_HOST_RE.test(host);
}

// Rewrites any request to a Zalo host into the gateway path convention
// http://<gateway>/<original-host>/<path>?<query>. Other urls pass
// through untouched.
export function mockGatewayFetch(baseUrl: string): typeof fetch {
  const base = baseUrl.replace(/\/+$/, "");
  const impl = (
    input: string | URL | Request,
    init?: RequestInit,
  ): Promise<Response> => {
    const raw =
      typeof input === "string"
        ? input
        : input instanceof URL
          ? input.toString()
          : input.url;
    const url = new URL(raw);
    const target = isZaloHost(url.hostname)
      ? `${base}/${url.hostname}${url.pathname}${url.search}`
      : raw;
    return fetch(target, init);
  };
  return impl as typeof fetch;
}

export function zaloMockUrl(): string | undefined {
  return process.env.ZALOS_ZALO_MOCK_URL;
}
