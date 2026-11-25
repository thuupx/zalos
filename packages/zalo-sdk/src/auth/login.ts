import type { ZaloContext, ZaloCredentials } from "../core/context.ts";
import { ZaloCookieJar } from "../core/cookies.ts";
import { computeSignKey, encryptPassword, ParamsEncryptor } from "../core/crypto.ts";
import { ZaloApiError } from "../core/errors.ts";
import type { ZaloHttpClient } from "../core/http.ts";
import type { LinkedDevice } from "../models/entities.ts";
import type { ZaloListener } from "../ws/listener.ts";

export interface LoginInfoResult {
  uid: string;
  zpw_enk: string;
  zpw_ws: string[];
  zpw_service_map_v3: Record<string, string[]>;
  [key: string]: unknown;
}

export interface ServerInfoResult {
  setttings?: Record<string, unknown>;
  settings?: Record<string, unknown>;
  extra_ver?: Record<string, unknown>;
  enable_encrypt_param?: boolean;
  server_time?: number;
  qr_format_trust_device?: boolean;
  [key: string]: unknown;
}

export interface PasswordLoginOptions {
  phone: string;
  password: string;
  countryCode?: string;
  captchaToken?: string;
  captchaAnswer?: string;
  imei?: string;
  cookie?: unknown;
}

/**
 * Fetches session bootstrap info (`uid`, `zpw_enk`, `zpw_service_map_v3`, `zpw_ws`)
 * using `ParamsEncryptor` (v2 AES-256-CBC) + `signkey`, falling back to plain query params
 * on `error_code === 19000`.
 */
export async function getLoginInfo(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  encryptParams = true,
): Promise<LoginInfoResult> {
  const authBase = ctx.profile.authDomain;
  const payload = {
    computer_name: ctx.computerName,
    imei: ctx.imei,
    language: ctx.language,
    ts: Date.now(),
  };

  if (!encryptParams) {
    const query = {
      ...payload,
      type: ctx.apiType,
      client_version: ctx.apiVersion,
      signkey: computeSignKey("getlogininfo", {
        computer_name: payload.computer_name,
        imei: payload.imei,
        language: payload.language,
        ts: payload.ts,
        type: ctx.apiType,
        client_version: ctx.apiVersion,
      }),
      nretry: 0,
    };
    const url = http.makeURL(`${authBase}/api/login/getLoginInfo`, query, false);
    const res = await http.requestRaw(url, { method: "GET" });
    return http.resolveEnvelope<LoginInfoResult>(res, false);
  }

  const encryptor = new ParamsEncryptor(ctx.apiType, ctx.imei);
  const encParams = encryptor.getParams();
  const paramsStr = encryptor.encrypt(payload);
  const signkey = computeSignKey("getlogininfo", {
    zcid: encParams.zcid,
    zcid_ext: encParams.zcid_ext,
    enc_ver: encParams.enc_ver,
    params: paramsStr,
    type: ctx.apiType,
    client_version: ctx.apiVersion,
  });

  const url = http.makeURL(
    `${authBase}/api/login/getLoginInfo`,
    {
      ...encParams,
      params: paramsStr,
      type: ctx.apiType,
      client_version: ctx.apiVersion,
      signkey,
      nretry: 0,
    },
    false,
  );
  const res = await http.requestRaw(url, { method: "GET" });
  const text = await res.text();
  if (!res.ok) {
    throw new ZaloApiError(`getLoginInfo failed with HTTP ${res.status}`, res.status, text);
  }
  const outer = JSON.parse(text) as { error_code: number; error_message?: string; data?: string };
  if (outer.error_code === 19000) {
    return getLoginInfo(http, ctx, false);
  }
  if ((outer.error_code !== undefined && outer.error_code !== 0) || typeof outer.data !== "string") {
    throw new ZaloApiError(
      outer.error_message || `getLoginInfo failed (${outer.error_code})`,
      outer.error_code,
      outer,
    );
  }
  const inner = encryptor.decrypt<{ error_code?: number; error_message?: string; data?: LoginInfoResult }>(
    outer.data,
  );
  if ((inner.error_code !== undefined && inner.error_code !== 0) || !inner.data) {
    throw new ZaloApiError(
      inner.error_message || `getLoginInfo inner error (${inner.error_code})`,
      inner.error_code,
      inner,
    );
  }
  return inner.data;
}

export async function getServerInfo(
  http: ZaloHttpClient,
  ctx: ZaloContext,
): Promise<ServerInfoResult> {
  const authBase = ctx.profile.authDomain;
  const baseFields = {
    imei: ctx.imei,
    type: ctx.apiType,
    client_version: ctx.apiVersion,
    computer_name: ctx.computerName,
  };
  const signkey = computeSignKey("getserverinfo", baseFields);
  const url = http.makeURL(`${authBase}/api/login/getServerInfo`, { ...baseFields, signkey }, false);
  const res = await http.requestRaw(url, { method: "GET" });
  return http.resolveEnvelope<ServerInfoResult>(res, false);
}

/**
 * Authenticates an existing session using stored `imei`, `cookie` jar, and `userAgent`.
 */
export async function loginWithCookie(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  credentials: ZaloCredentials,
): Promise<void> {
  if (credentials.userAgent) ctx.userAgent = credentials.userAgent;
  if (credentials.language) ctx.language = credentials.language;
  ctx.imei = credentials.imei;
  ctx.cookie = new ZaloCookieJar(credentials.cookie);

  const [loginInfo, serverInfo] = await Promise.all([
    getLoginInfo(http, ctx),
    getServerInfo(http, ctx),
  ]);

  if (!loginInfo.uid || !loginInfo.zpw_enk) {
    throw new ZaloApiError("Login failed: missing uid or zpw_enk", null, loginInfo);
  }

  ctx.uid = String(loginInfo.uid);
  ctx.secretKey = loginInfo.zpw_enk;
  ctx.zpwServiceMap = loginInfo.zpw_service_map_v3 ?? {};
  ctx.wsUrls = Array.isArray(loginInfo.zpw_ws) ? [...loginInfo.zpw_ws] : [];
  ctx.settings =
    (serverInfo.setttings as Record<string, unknown> | undefined) ??
    (serverInfo.settings as Record<string, unknown> | undefined) ??
    {};
  ctx.extraVer = (serverInfo.extra_ver as Record<string, unknown> | undefined) ?? {};
}

export async function getLoginCaptcha(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  language = ctx.language,
): Promise<unknown> {
  const encryptor = new ParamsEncryptor(ctx.apiType, ctx.imei);
  const enc = encryptor.getParams();
  const payload = { imei: ctx.imei, language };
  const paramsStr = encryptor.encrypt(payload);
  const signkey = computeSignKey("getcaptcha", {
    ...enc,
    params: paramsStr,
    type: ctx.apiType,
    client_version: ctx.apiVersion,
  });
  const url = http.makeURL(
    `${ctx.profile.authDomain}/api/login/getCaptcha`,
    { ...enc, params: paramsStr, type: ctx.apiType, client_version: ctx.apiVersion, signkey },
    false,
  );
  const res = await http.requestRaw(url, { method: "GET" });
  const outer = (await res.json()) as { error_code: number; error_message?: string; data?: string };
  if (outer.error_code !== 0 || typeof outer.data !== "string") {
    throw new ZaloApiError(outer.error_message || "Failed to get captcha", outer.error_code, outer);
  }
  return encryptor.decrypt(outer.data);
}

/**
 * Password-based login (`/api/login/loginByPasswv2`) per Zalo PC protocol.
 */
export async function loginWithPassword(
  http: ZaloHttpClient,
  ctx: ZaloContext,
  opts: PasswordLoginOptions,
): Promise<LoginInfoResult> {
  if (opts.imei) ctx.imei = opts.imei;
  if (opts.cookie) ctx.cookie = new ZaloCookieJar(opts.cookie);

  const { encryptedPassword } = encryptPassword(opts.phone, ctx.imei, opts.password);
  const encryptor = new ParamsEncryptor(ctx.apiType, ctx.imei);
  const enc = encryptor.getParams();
  const innerPayload: Record<string, unknown> = {
    phone_num: opts.phone,
    password: encryptedPassword,
    country_code: opts.countryCode ?? "84",
    imei: ctx.imei,
    language: ctx.language,
    computer_name: ctx.computerName,
    ts: Date.now(),
    ...(opts.captchaToken ? { token_captcha: opts.captchaToken } : {}),
    ...(opts.captchaAnswer ? { captcha_str: opts.captchaAnswer } : {}),
  };
  const paramsStr = encryptor.encrypt(innerPayload);
  const signkey = computeSignKey("loginbypasswv2", {
    ...enc,
    params: paramsStr,
    type: ctx.apiType,
    client_version: ctx.apiVersion,
  });

  const url = http.makeURL(
    `${ctx.profile.authDomain}/api/login/loginByPasswv2`,
    { ...enc, type: ctx.apiType, client_version: ctx.apiVersion, signkey },
    false,
  );
  const res = await http.requestRaw(url, {
    method: "POST",
    kind: "form",
    body: new URLSearchParams({ params: paramsStr }),
  });
  const outer = (await res.json()) as { error_code: number; error_message?: string; data?: string };
  if (outer.error_code !== 0 || typeof outer.data !== "string") {
    throw new ZaloApiError(outer.error_message || "Password login failed", outer.error_code, outer);
  }
  const inner = encryptor.decrypt<{ error_code: number; error_message?: string; data?: LoginInfoResult & { zpw_sek?: string } }>(
    outer.data,
  );
  if (inner.error_code !== 0 || !inner.data) {
    throw new ZaloApiError(
      inner.error_message || "Password login rejected",
      inner.error_code,
      inner,
    );
  }
  if (inner.data.zpw_sek) {
    ctx.cookie.mirrorSessionCookie("zpw_sek", inner.data.zpw_sek);
  }
  return inner.data;
}

export async function logoutSession(
  http: ZaloHttpClient,
  listener?: ZaloListener,
): Promise<boolean> {
  listener?.stop();
  const resToken = await http.requestRaw("https://id.zalo.me/jr/logout-token", {
    method: "POST",
    kind: "form",
    body: new URLSearchParams({ continue: "https://chat.zalo.me/" }),
  });
  const tokenJson = (await resToken.json()) as { data?: { token?: string } };
  const token = tokenJson?.data?.token;
  if (!token) return false;

  const resLogout = await http.requestRaw("https://id.zalo.me/account/logout", {
    method: "POST",
    kind: "form",
    body: new URLSearchParams({ token }),
  });
  const html = await resLogout.text();
  const match = html.match(/listSetSidUrls\s*=\s*(\[[^\]]*\])/);
  if (match) {
    const urls = JSON.parse(match[1]!) as string[];
    await Promise.allSettled(
      urls.map((u) =>
        http.requestRaw(u, {
          method: "GET",
          headerOverrides: { Referer: "https://id.zalo.me/" },
        }),
      ),
    );
  }
  return true;
}

export async function keepAlive(http: ZaloHttpClient, ctx: ZaloContext): Promise<unknown> {
  const url = http.serviceUrl("chat", "/keepalive");
  return http.getEncrypted(url, { imei: ctx.imei }, { decryptResponse: false });
}

export async function getListDevice(
  http: ZaloHttpClient,
  ctx: ZaloContext,
): Promise<LinkedDevice[]> {
  const url = http.serviceUrl("aext", "/api/devices/linked");
  return http.getEncrypted<LinkedDevice[]>(url, { imei: ctx.imei });
}
