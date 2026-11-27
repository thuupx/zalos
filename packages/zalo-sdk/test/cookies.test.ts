import { describe, expect, test } from "bun:test";
import { ZaloCookieJar } from "../src/core/cookies.ts";

function headersWith(...cookies: string[]): Headers {
  const h = new Headers();
  for (const c of cookies) h.append("set-cookie", c);
  return h;
}

describe("ZaloCookieJar.ingestResponse", () => {
  test("keeps session cookies id.zalo.me sets for chat.zalo.me", () => {
    const jar = new ZaloCookieJar();
    jar.ingestResponse(
      "https://id.zalo.me/account/checksession?continue=https%3A%2F%2Fchat.zalo.me%2Findex.html",
      headersWith(
        "zpsid=abc; Domain=chat.zalo.me; Path=/; Secure; HttpOnly",
        "zpw_sek=def; Domain=.chat.zalo.me; Path=/; Expires=Wed, 18 Mar 2099 10:00:00 GMT; Secure",
      ),
    );
    const sent = jar.getCookieStringSync("https://jr.chat.zalo.me/jr/userinfo");
    expect(sent).toContain("zpw_sek=def");
    expect(jar.getCookieStringSync("https://chat.zalo.me/")).toContain("zpsid=abc");
    // Not leaked to a non-matching host.
    expect(jar.getCookieStringSync("https://id.zalo.me/")).not.toContain("zpsid");
  });

  test("still stores ordinary same-host and parent-domain cookies", () => {
    const jar = new ZaloCookieJar();
    jar.ingestResponse(
      "https://id.zalo.me/account",
      headersWith("zpdid=1; Domain=.id.zalo.me; Path=/", "_zlang=vn; Path=/; Domain=zalo.me", "hostonly=2; Path=/"),
    );
    const s = jar.getCookieStringSync("https://id.zalo.me/account/logininfo");
    expect(s).toContain("zpdid=1");
    expect(s).toContain("_zlang=vn");
    expect(s).toContain("hostonly=2");
    expect(jar.getCookieStringSync("https://chat.zalo.me/")).toContain("_zlang=vn");
    expect(jar.getCookieStringSync("https://chat.zalo.me/")).not.toContain("hostonly");
  });

  test("ignores non-Zalo cross-domain cookies", () => {
    const jar = new ZaloCookieJar();
    jar.ingestResponse("https://id.zalo.me/", headersWith("evil=1; Domain=example.com; Path=/"));
    expect(jar.getCookieStringSync("https://example.com/")).toBe("");
  });
});
