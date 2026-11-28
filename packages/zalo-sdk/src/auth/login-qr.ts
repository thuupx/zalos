import { writeFile } from "node:fs/promises";
import type { ZaloContext, ZaloCredentials } from "../core/context.ts";
import { computeSignKey, ParamsEncryptor } from "../core/crypto.ts";
import { ZaloApiError } from "../core/errors.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import { LoginQRCallbackEventType } from "../models/enums.ts";
import type { LoginQRCallbackEvent } from "../models/events.ts";
import { getServerInfo, loginWithCookie } from "./login.ts";

export interface LoginQRCallbacks {
  (event: LoginQRCallbackEvent): void;
}

export interface LoginQROptions {
  userAgent?: string;
  language?: string;
  qrPath?: string;
  signal?: AbortSignal;
}

const DEFAULT_ID_ZALO = "https://id.zalo.me";
const WEB_CONTINUE = "https://chat.zalo.me/";
const QR_CONTINUE = "https://zalo.me/pc";
// id.zalo.me rejects the QR endpoints with error -4 ("Truy cập không hợp lệ")
// unless the request looks like it comes from its own login page.
const ID_PAGE_HEADERS: Record<string, string> = {
  Origin: DEFAULT_ID_ZALO,
  Referer: `${DEFAULT_ID_ZALO}/account?continue=${encodeURIComponent(QR_CONTINUE)}`,
};
// waiting-scan / waiting-confirm / checksession run on the chat.zalo.me page.
const ID_CHAT_PAGE_HEADERS: Record<string, string> = {
  Origin: DEFAULT_ID_ZALO,
  Referer: `${DEFAULT_ID_ZALO}/account?continue=${encodeURIComponent(WEB_CONTINUE)}`,
};

/**
 * Zalo Web QR Login flow (`id.zalo.me/account/authen/qr/*`) also served by the offline mock.
 */
export async function loginQRWeb(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  options: LoginQROptions = {},
  callback?: LoginQRCallbacks,
): Promise<ZaloCredentials | null> {
  if (options.userAgent) ctx.userAgent = options.userAgent;
  if (options.language) ctx.language = options.language;

  let aborted = false;
  const onAbort = () => {
    aborted = true;
  };
  options.signal?.addEventListener("abort", onAbort, { once: true });

  const runAttempt = async (): Promise<ZaloCredentials | null> => {
    if (aborted) throw new ZaloApiError("QR login aborted");

    // Step 1: Load login page & scrape JS bundle version
    const pageUrl = `${DEFAULT_ID_ZALO}/account?continue=${encodeURIComponent(WEB_CONTINUE)}`;
    const pageRes = await http.requestRaw(pageUrl, { method: "GET" });
    const html = await pageRes.text();
    const versionMatch = html.match(/https:\/\/stc-zlogin\.zdn\.vn\/main-([\d.]+)\.js/);
    const version = versionMatch?.[1] ?? "1.0.0";

    // Step 2: Init login info & verify client
    await http.requestRaw(`${DEFAULT_ID_ZALO}/account/logininfo`, {
      method: "POST",
      kind: "form",
      headerOverrides: ID_PAGE_HEADERS,
      body: new URLSearchParams({ continue: QR_CONTINUE, v: version }),
    });
    await http.requestRaw(`${DEFAULT_ID_ZALO}/account/verify-client`, {
      method: "POST",
      kind: "form",
      headerOverrides: ID_PAGE_HEADERS,
      body: new URLSearchParams({ type: "device", continue: QR_CONTINUE, v: version }),
    });

    // Step 3: Generate QR
    const genRes = await http.requestRaw(`${DEFAULT_ID_ZALO}/account/authen/qr/generate`, {
      method: "POST",
      kind: "form",
      headerOverrides: ID_PAGE_HEADERS,
      body: new URLSearchParams({ continue: QR_CONTINUE, v: version }),
    });
    const genJson = (await genRes.json()) as {
      error_code: number;
      error_message?: string;
      data?: { code?: string; image?: string; options?: Record<string, unknown> };
    };
    if (genJson.error_code !== 0 || !genJson.data?.code || !genJson.data?.image) {
      throw new ZaloApiError(
        genJson.error_message || "Failed to generate QR code",
        genJson.error_code,
        genJson,
      );
    }

    const code = genJson.data.code;
    const image = genJson.data.image;

    let wantRetry = false;
    let expired = false;
    const expiryTimer = setTimeout(() => {
      expired = true;
      callback?.({
        type: LoginQRCallbackEventType.QRCodeExpired,
        data: null,
        actions: {
          retry: () => {
            wantRetry = true;
          },
          abort: () => {
            aborted = true;
          },
        },
      });
    }, 100_000);

    try {
      callback?.({
        type: LoginQRCallbackEventType.QRCodeGenerated,
        data: { code, image, options: genJson.data.options ?? {} },
        actions: {
          saveToFile: async (qrPath = options.qrPath ?? "qr.png") => {
            const base64 = image.replace(/^data:image\/\w+;base64,/, "");
            await writeFile(qrPath, Buffer.from(base64, "base64"));
          },
          retry: () => {
            wantRetry = true;
          },
          abort: () => {
            aborted = true;
          },
        },
      });

      // Step 4: Long-poll waiting-scan
      while (true) {
        if (aborted) throw new ZaloApiError("QR login aborted");
        if (wantRetry) return runAttempt();
        if (expired) throw new ZaloApiError("QR code expired");

        const scanRes = await http.requestRaw(`${DEFAULT_ID_ZALO}/account/authen/qr/waiting-scan`, {
          method: "POST",
          kind: "form",
          headerOverrides: ID_CHAT_PAGE_HEADERS,
          body: new URLSearchParams({ code, continue: WEB_CONTINUE, v: version }),
        });
        const scanJson = (await scanRes.json()) as {
          error_code: number;
          error_message?: string;
          data?: { avatar?: string; display_name?: string; [key: string]: unknown };
        };
        if (scanJson.error_code === 8) continue;
        if (scanJson.error_code === -2) {
          callback?.({
            type: LoginQRCallbackEventType.QRCodeExpired,
            data: null,
            actions: {
              retry: () => {
                wantRetry = true;
              },
              abort: () => {
                aborted = true;
              },
            },
          });
          if (wantRetry) return runAttempt();
          throw new ZaloApiError("QR code expired", -2);
        }
        if (scanJson.error_code !== 0) {
          throw new ZaloApiError(
            scanJson.error_message || "QR waiting-scan failed",
            scanJson.error_code,
            scanJson,
          );
        }

        clearTimeout(expiryTimer);
        callback?.({
          type: LoginQRCallbackEventType.QRCodeScanned,
          data: {
            avatar: scanJson.data?.avatar ?? "",
            display_name: scanJson.data?.display_name ?? "",
            ...(scanJson.data ?? {}),
          },
          actions: {
            retry: () => {
              wantRetry = true;
            },
            abort: () => {
              aborted = true;
            },
          },
        });
        break;
      }

      // Step 5: Long-poll waiting-confirm
      while (true) {
        if (aborted) throw new ZaloApiError("QR login aborted");
        if (wantRetry) return runAttempt();

        const cfirmRes = await http.requestRaw(`${DEFAULT_ID_ZALO}/account/authen/qr/waiting-confirm`, {
          method: "POST",
          kind: "form",
          headerOverrides: ID_CHAT_PAGE_HEADERS,
          body: new URLSearchParams({
            code,
            gToken: "",
            gAction: "CONFIRM_QR",
            continue: WEB_CONTINUE,
            v: version,
          }),
        });
        const cfirmJson = (await cfirmRes.json()) as {
          error_code: number;
          error_message?: string;
          data?: Record<string, unknown>;
        };
        if (cfirmJson.error_code === 8) continue;
        if (cfirmJson.error_code === -13) {
          if (callback) {
            callback({
              type: LoginQRCallbackEventType.QRCodeDeclined,
              data: { code, ...(cfirmJson.data ?? {}) },
              actions: {
                retry: () => {
                  wantRetry = true;
                },
                abort: () => {
                  aborted = true;
                },
              },
            });
            if (wantRetry) return runAttempt();
            return null;
          }
          throw new ZaloApiError("QR login declined on mobile device", -13);
        }
        if (cfirmJson.error_code !== 0) {
          throw new ZaloApiError(
            cfirmJson.error_message || "QR waiting-confirm failed",
            cfirmJson.error_code,
            cfirmJson,
          );
        }
        break;
      }

      // Step 6: Check session and follow the whole redirect chain by hand,
      // ingesting Set-Cookie at every hop (fetch would drop intermediate ones).
      const hops: string[] = [];
      let nextUrl: string | null =
        `${DEFAULT_ID_ZALO}/account/checksession?continue=${encodeURIComponent(`${WEB_CONTINUE}index.html`)}`;
      let referer = `${DEFAULT_ID_ZALO}/account?continue=${encodeURIComponent(WEB_CONTINUE)}`;
      for (let i = 0; nextUrl !== null && i < 10; i++) {
        const hopRes: Response = await http.requestRaw(nextUrl, {
          method: "GET",
          redirect: "manual",
          kind: "raw",
          headerOverrides: { Referer: referer },
        });
        hops.push(`${hopRes.status} ${new URL(nextUrl).host}${new URL(nextUrl).pathname}`);
        const loc = hopRes.headers.get("location");
        await hopRes.body?.cancel().catch(() => {});
        nextUrl = loc ? new URL(loc, nextUrl).toString() : null;
        referer = `${DEFAULT_ID_ZALO}/`;
      }

      // Step 7: Confirm jr/userinfo logged === true
      const jrRes = await http.requestRaw("https://jr.chat.zalo.me/jr/userinfo", {
        method: "GET",
        headerOverrides: { Referer: WEB_CONTINUE, Origin: "https://chat.zalo.me" },
      });
      const jrJson = (await jrRes.json()) as { data?: { logged?: boolean } };
      if (!jrJson?.data?.logged) {
        const cookieNames = ctx.cookie
          .toJSON()
          .cookies.map((c: { key?: string; domain?: string }) => `${c.key}@${c.domain}`);
        throw new ZaloApiError("Failed to confirm logged-in state via /jr/userinfo", null, {
          jr: jrJson,
          hops,
          cookies: cookieNames,
        });
      }

      const creds: ZaloCredentials = {
        imei: ctx.imei,
        cookie: ctx.cookie.toJSON(),
        userAgent: ctx.userAgent,
        language: ctx.language,
      };
      await loginWithCookie(http, ctx, creds);

      callback?.({
        type: LoginQRCallbackEventType.GotLoginInfo,
        data: {
          cookie: ctx.cookie.toJSON().cookies,
          imei: ctx.imei,
          userAgent: ctx.userAgent,
          uid: ctx.uid,
        },
        actions: null,
      });

      return creds;
    } finally {
      clearTimeout(expiryTimer);
    }
  };

  try {
    return await runAttempt();
  } finally {
    options.signal?.removeEventListener("abort", onAbort);
  }
}

/**
 * Native Zalo PC QR Login flow (`wpa.zaloapp.com/api/login/reqqr` + `chk_wait_scan`/`chk_wait_cfirm`).
 */
export async function loginQRPc(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  options: LoginQROptions & { loggedUids?: string[] } = {},
  callback?: LoginQRCallbacks,
): Promise<ZaloCredentials> {
  if (options.userAgent) ctx.userAgent = options.userAgent;
  if (options.language) ctx.language = options.language;

  await getServerInfo(http, ctx);

  const encryptor = new ParamsEncryptor(ctx.apiType, ctx.imei);
  const enc = encryptor.getParams();
  const reqPayload = {
    language: ctx.language,
    client_time: Date.now(),
    imei: ctx.imei,
    computer_name: ctx.computerName,
    logged_uids: options.loggedUids ?? [],
    self_g: 0,
    qr_form: 0,
  };
  const paramsStr = encryptor.encrypt(reqPayload);
  const signkey = computeSignKey("reqqr", {
    ...enc,
    params: paramsStr,
    type: ctx.apiType,
    client_version: ctx.apiVersion,
  });

  const reqUrl = http.makeURL(
    `${ctx.profile.authDomain}/api/login/reqqr`,
    { ...enc, params: paramsStr, type: ctx.apiType, client_version: ctx.apiVersion, signkey },
    false,
  );
  const qrRes = await http.requestRaw(reqUrl, { method: "GET" });
  const qrOuter = (await qrRes.json()) as { error_code: number; error_message?: string; data?: string };
  if (qrOuter.error_code !== 0 || typeof qrOuter.data !== "string") {
    throw new ZaloApiError(qrOuter.error_message || "reqqr failed", qrOuter.error_code, qrOuter);
  }

  const qrInner = encryptor.decrypt<{
    error_code: number;
    error_message?: string;
    data?: {
      base64_qr: string;
      chk_wait_scan: string;
      chk_wait_cfirm: string;
      token_id: string;
      qr_retry?: number;
      qr_timeout?: number;
    };
  }>(qrOuter.data);

  if (qrInner.error_code !== 0 || !qrInner.data) {
    throw new ZaloApiError(qrInner.error_message || "reqqr inner failed", qrInner.error_code, qrInner);
  }

  const { base64_qr, chk_wait_scan, chk_wait_cfirm, token_id } = qrInner.data;
  const imageDataUri = base64_qr.startsWith("data:")
    ? base64_qr
    : `data:image/png;base64,${base64_qr}`;

  let aborted = false;
  options.signal?.addEventListener("abort", () => {
    aborted = true;
  }, { once: true });

  callback?.({
    type: LoginQRCallbackEventType.QRCodeGenerated,
    data: { code: token_id, image: imageDataUri, options: {}, tokenId: token_id },
    actions: {
      saveToFile: async (qrPath = options.qrPath ?? "qr.png") => {
        await writeFile(qrPath, Buffer.from(imageDataUri.replace(/^data:image\/\w+;base64,/, ""), "base64"));
      },
      retry: () => {},
      abort: () => {
        aborted = true;
      },
    },
  });

  // Poll chk_wait_scan
  const maxRetry = qrInner.data.qr_retry ?? 10;
  for (let attempt = 0; attempt < maxRetry; attempt++) {
    if (aborted) throw new ZaloApiError("PC QR login aborted");
    const scanRes = await http.requestRaw(chk_wait_scan, { method: "GET" });
    const scanOuter = (await scanRes.json()) as { error_code: number; data?: string };
    if (scanOuter.error_code === 8 || scanOuter.error_code === 408) continue;
    if (scanOuter.error_code === -2 || scanOuter.error_code === -20) {
      throw new ZaloApiError("PC QR code expired or requires renewal", scanOuter.error_code, scanOuter);
    }
    if (scanOuter.error_code === 0 && typeof scanOuter.data === "string") {
      const scanInner = encryptor.decrypt<{
        error_code: number;
        data?: { avatar?: string; display_name?: string; [k: string]: unknown };
      }>(scanOuter.data);
      if (scanInner.error_code === 8) continue;
      if (scanInner.error_code === 0) {
        callback?.({
          type: LoginQRCallbackEventType.QRCodeScanned,
          data: {
            avatar: scanInner.data?.avatar ?? "",
            display_name: scanInner.data?.display_name ?? "",
            ...(scanInner.data ?? {}),
          },
          actions: { retry: () => {}, abort: () => { aborted = true; } },
        });
        break;
      }
    }
  }

  // Poll chk_wait_cfirm
  for (let attempt = 0; attempt < maxRetry; attempt++) {
    if (aborted) throw new ZaloApiError("PC QR login aborted");
    const cfirmRes = await http.requestRaw(chk_wait_cfirm, { method: "GET" });
    const cfirmOuter = (await cfirmRes.json()) as { error_code: number; data?: string };
    if (cfirmOuter.error_code === 8) continue;
    if (cfirmOuter.error_code === 18010 || cfirmOuter.error_code === -13) {
      throw new ZaloApiError("PC QR login rejected on mobile", cfirmOuter.error_code);
    }
    if (cfirmOuter.error_code === 0 && typeof cfirmOuter.data === "string") {
      const cfirmInner = encryptor.decrypt<{
        error_code: number;
        data?: { uid: string; zpw_sek: string; zpw_kt?: string; [k: string]: unknown };
      }>(cfirmOuter.data);
      if (cfirmInner.error_code === 8) continue;
      if (cfirmInner.error_code === 18010 || cfirmInner.error_code === -13) {
        throw new ZaloApiError("PC QR login rejected on mobile", cfirmInner.error_code);
      }
      if (cfirmInner.error_code === 0 && cfirmInner.data?.zpw_sek) {
        ctx.cookie.mirrorSessionCookie("zpw_sek", cfirmInner.data.zpw_sek);
        const creds: ZaloCredentials = {
          imei: ctx.imei,
          cookie: ctx.cookie.toJSON(),
          userAgent: ctx.userAgent,
          language: ctx.language,
        };
        await loginWithCookie(http, ctx, creds);
        callback?.({
          type: LoginQRCallbackEventType.GotLoginInfo,
          data: {
            cookie: ctx.cookie.toJSON().cookies,
            imei: ctx.imei,
            userAgent: ctx.userAgent,
            uid: ctx.uid,
            zpw_kt: cfirmInner.data.zpw_kt,
          },
          actions: null,
        });
        return creds;
      }
    }
  }

  throw new ZaloApiError("PC QR login timed out waiting for confirmation");
}
