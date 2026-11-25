import { Cookie, CookieJar, type SerializedCookie, type SerializedCookieJar } from "tough-cookie";

export type CookieInput =
  | CookieJar
  | SerializedCookieJar
  | { cookies?: unknown[] }
  | SerializedCookie[]
  | Cookie[]
  | string;

const ZALO_SESSION_DOMAINS = [
  "https://zaloapp.com",
  "https://zalo.me",
  "https://chat.zalo.me",
] as const;

export class ZaloCookieJar {
  readonly jar: CookieJar;

  constructor(input?: CookieInput) {
    if (input instanceof CookieJar) {
      this.jar = input;
    } else if (Array.isArray(input)) {
      this.jar = new CookieJar();
      for (const c of input) {
        const cookie = c instanceof Cookie ? c : Cookie.fromJSON(c as Record<string, unknown>);
        if (cookie && cookie.key) {
          const domain = (cookie.domain ?? "chat.zalo.me").replace(/^\./, "");
          const scheme = cookie.secure === false ? "http" : "https";
          try {
            this.jar.setCookieSync(cookie, `${scheme}://${domain}${cookie.path ?? "/"}`, {
              ignoreError: true,
            });
          } catch {
            // Skip invalid cookie entries on restore.
          }
        }
      }
    } else if (input && typeof input === "object") {
      const obj = input as SerializedCookieJar;
      if (Array.isArray(obj.cookies)) {
        try {
          this.jar = CookieJar.fromJSON({
            version: obj.version ?? "tough-cookie@5.1.2",
            storeType: obj.storeType ?? "MemoryCookieStore",
            rejectPublicSuffixes: obj.rejectPublicSuffixes ?? false,
            cookies: obj.cookies,
          });
        } catch {
          this.jar = new ZaloCookieJar(obj.cookies).jar;
        }
      } else {
        this.jar = new CookieJar();
      }
    } else if (typeof input === "string" && input.trim()) {
      this.jar = new CookieJar();
      for (const part of input.split(";")) {
        const trimmed = part.trim();
        if (!trimmed || !trimmed.includes("=")) continue;
        this.jar.setCookieSync(`${trimmed}; Domain=zalo.me; Path=/`, "https://chat.zalo.me/", {
          ignoreError: true,
        });
      }
    } else {
      this.jar = new CookieJar();
    }
  }

  ingestResponse(url: string, headers: Headers): void {
    const rawList =
      typeof headers.getSetCookie === "function"
        ? headers.getSetCookie()
        : splitCombinedSetCookie(headers.get("set-cookie"));
    for (const raw of rawList) {
      if (!raw) continue;
      try {
        this.jar.setCookieSync(raw, url, { ignoreError: true });
      } catch {
        // Ignore malformed Set-Cookie attributes.
      }
    }
  }

  setCookie(cookieStr: string, url = "https://chat.zalo.me/"): void {
    this.jar.setCookieSync(cookieStr, url, { ignoreError: true });
  }

  mirrorSessionCookie(name: string, value: string, maxAgeSec = 7 * 24 * 3600): void {
    for (const origin of ZALO_SESSION_DOMAINS) {
      const domain = new URL(origin).hostname;
      this.jar.setCookieSync(
        `${name}=${value}; Domain=.${domain}; Path=/; Max-Age=${maxAgeSec}; Secure; HttpOnly; SameSite=None`,
        origin,
        { ignoreError: true },
      );
    }
  }

  getCookieStringSync(url: string): string {
    return this.jar.getCookieStringSync(url);
  }

  toJSON(): SerializedCookieJar {
    return this.jar.toJSON() as SerializedCookieJar;
  }
}

function splitCombinedSetCookie(header: string | null): string[] {
  if (!header) return [];
  // Split commas that start a new cookie pair while preserving Expires=Wed, ... dates.
  return header.split(/,(?=\s*[!#$%&'*+\-.^_`|~0-9A-Za-z]+=)/g).map((s) => s.trim());
}
