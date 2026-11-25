import { DEFAULT_SERVICE_DOMAINS } from "./constants.ts";
import type { FetchLike, ZaloContext } from "./context.ts";
import { decodeAES, encodeAES, parseJsonSafe } from "./crypto.ts";
import { ZaloApiError, ZaloNetworkError } from "./errors.ts";

export interface EncryptedRequestOptions {
  /** Override API version query params (default true). */
  apiVersion?: boolean;
  /** Expect AES-encrypted `data` field in envelope (default true). */
  decryptResponse?: boolean;
  /** Append `nretry=0` to query string. */
  nretry?: boolean;
  /** Extra unencrypted query params alongside `zpw_ver`, `zpw_type`, `params`. */
  extraQuery?: Record<string, string | number | boolean | undefined>;
  /** Extra HTTP headers. */
  headers?: Record<string, string>;
  /** Treat HTTP request as image fetch for Chromium-style fetch headers. */
  imageRequest?: boolean;
  /** Failover service key for domain rotation on network/5xx errors. */
  serviceKey?: string;
}

export interface ApiEnvelope<T = unknown> {
  error_code: number;
  error_message?: string;
  data?: T;
}

const FAILOVER_RESET_MS = 5 * 60 * 1000;

/**
 * Serialized FIFO async queue with per-task timeout (used by call signaling when enabled).
 */
export class SerializedQueue {
  private tail: Promise<void> = Promise.resolve();
  private readonly defaultTimeoutMs: number;

  constructor(defaultTimeoutMs = 30_000) {
    this.defaultTimeoutMs = defaultTimeoutMs;
  }

  enqueue<T>(fn: () => Promise<T>, timeoutMs = this.defaultTimeoutMs): Promise<T> {
    const run = this.tail.then(
      () => withTimeout(fn(), timeoutMs),
      () => withTimeout(fn(), timeoutMs),
    );
    this.tail = run.then(
      () => undefined,
      () => undefined,
    );
    return run;
  }
}

function withTimeout<T>(promise: Promise<T>, ms: number): Promise<T> {
  if (ms <= 0 || !Number.isFinite(ms)) return promise;
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new ZaloNetworkError(`Request queue timeout after ${ms} ms`));
    }, ms);
    promise.then(
      (v) => {
        clearTimeout(timer);
        resolve(v);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}

export class ZaloHttpClient {
  readonly ctx: ZaloContext;
  private readonly fetchFn: FetchLike;
  private readonly domainIndex = new Map<string, { idx: number; switchedAt: number }>();
  readonly callQueue = new SerializedQueue(30_000);

  constructor(ctx: ZaloContext, fetchFn?: FetchLike) {
    this.ctx = ctx;
    this.fetchFn = fetchFn ?? ((input, init) => globalThis.fetch(input, init));
  }

  /**
   * Resolves the current active base URL for a `zpw_service_map_v3` key,
   * automatically resetting rotated failover indices after 5 minutes.
   */
  serviceDomains(serviceKey: string): string[] {
    const fromMap = this.ctx.zpwServiceMap[serviceKey];
    if (Array.isArray(fromMap) && fromMap.length > 0) return fromMap;
    const fallback = DEFAULT_SERVICE_DOMAINS[serviceKey];
    if (fallback && fallback.length > 0) return [...fallback];
    throw new ZaloApiError(`Service domain unavailable for key "${serviceKey}"`);
  }

  serviceBase(serviceKey: string): string {
    const domains = this.serviceDomains(serviceKey);
    const state = this.domainIndex.get(serviceKey);
    if (!state) return domains[0]!;
    if (Date.now() - state.switchedAt >= FAILOVER_RESET_MS) {
      this.domainIndex.delete(serviceKey);
      return domains[0]!;
    }
    return domains[state.idx % domains.length]!;
  }

  rotateServiceDomain(serviceKey: string): boolean {
    const domains = this.ctx.zpwServiceMap[serviceKey] ?? DEFAULT_SERVICE_DOMAINS[serviceKey];
    if (!domains || domains.length <= 1) return false;
    const current = this.domainIndex.get(serviceKey)?.idx ?? 0;
    const next = (current + 1) % domains.length;
    this.domainIndex.set(serviceKey, { idx: next, switchedAt: Date.now() });
    return true;
  }

  serviceUrl(
    serviceKey: string,
    path: string,
    query: Record<string, string | number | boolean | undefined> = {},
    includeApiVersion = true,
  ): string {
    const base = this.serviceBase(serviceKey).replace(/\/$/, "");
    const normalizedPath = path.startsWith("/") ? path : `/${path}`;
    return this.makeURL(`${base}${normalizedPath}`, query, includeApiVersion);
  }

  makeURL(
    baseURL: string,
    params: Record<string, string | number | boolean | undefined> = {},
    apiVersion = true,
  ): string {
    const url = new URL(baseURL);
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined) continue;
      url.searchParams.set(k, String(v));
    }
    if (apiVersion) {
      if (!url.searchParams.has("zpw_ver")) {
        url.searchParams.set("zpw_ver", String(this.ctx.apiVersion));
      }
      if (!url.searchParams.has("zpw_type")) {
        url.searchParams.set("zpw_type", String(this.ctx.apiType));
      }
    }
    return url.toString();
  }

  buildHeaders(
    url: string,
    kind: "xhr" | "form" | "multipart" | "image" | "raw" = "xhr",
    extra?: Record<string, string>,
  ): Headers {
    const headers = new Headers();
    const p = this.ctx.profile;

    headers.set("User-Agent", this.ctx.userAgent || p.userAgent);
    headers.set(
      "Accept",
      kind === "image"
        ? "image/webp,image/apng,image/*,*/*;q=0.8"
        : "application/json, text/plain, */*",
    );
    headers.set("Accept-Language", "en-US");
    if (p.secChUa) headers.set("sec-ch-ua", p.secChUa);
    if (p.secChUaPlatform) headers.set("sec-ch-ua-platform", p.secChUaPlatform);
    if (p.name !== "web") {
      headers.set("sec-ch-ua-mobile", "?0");
      headers.set("sec-fetch-dest", kind === "image" ? "image" : "empty");
      headers.set("sec-fetch-mode", kind === "image" ? "no-cors" : "cors");
      headers.set("sec-fetch-site", "cross-site");
    } else {
      if (p.origin) headers.set("Origin", p.origin);
      if (p.referer) headers.set("Referer", p.referer);
    }

    if (kind === "form") {
      headers.set("Content-Type", "application/x-www-form-urlencoded");
    } else if (kind === "xhr" && p.name !== "web") {
      // Zalo PC (axios) sends x-www-form-urlencoded even on GET XHRs.
      headers.set("Content-Type", "application/x-www-form-urlencoded");
    }

    const cookieHeader = this.ctx.cookie.getCookieStringSync(url);
    if (cookieHeader) {
      headers.set("Cookie", cookieHeader);
    }

    if (extra) {
      for (const [k, v] of Object.entries(extra)) {
        headers.set(k, v);
      }
    }
    return headers;
  }

  async requestRaw(
    url: string,
    init: RequestInit & { kind?: "xhr" | "form" | "multipart" | "image" | "raw"; headerOverrides?: Record<string, string> } = {},
  ): Promise<Response> {
    const { kind = "xhr", headerOverrides, ...fetchInit } = init;
    const headers = this.buildHeaders(url, kind, headerOverrides);
    if (init.headers) {
      new Headers(init.headers).forEach((value, key) => {
        headers.set(key, value);
      });
    }
    // Multipart requests must let Fetch/FormData set Content-Type with boundary.
    if (kind === "multipart" || fetchInit.body instanceof FormData) {
      headers.delete("Content-Type");
    }

    let response: Response;
    try {
      response = await this.fetchFn(url, {
        ...fetchInit,
        headers,
      });
    } catch (err) {
      throw new ZaloNetworkError(
        `HTTP request failed for ${url}: ${err instanceof Error ? err.message : String(err)}`,
        err,
      );
    }

    // Ingest cookies against the logical Zalo request URL so polyfills that rewrite
    // hostnames (e.g. local mock gateway) still satisfy Domain=zalo.me checks.
    this.ctx.cookie.ingestResponse(url, response.headers);
    return response;
  }

  encryptParams(params: unknown): string {
    if (!this.ctx.secretKey) {
      throw new ZaloApiError("Missing session secretKey (zpw_enk); call login() first");
    }
    const serialized = typeof params === "string" ? params : JSON.stringify(params);
    return encodeAES(this.ctx.secretKey, serialized, "base64");
  }

  async resolveEnvelope<T = unknown>(
    response: Response,
    decryptData = true,
  ): Promise<T> {
    if (!response.ok) {
      throw new ZaloApiError(`Request failed with status code ${response.status}`, response.status);
    }
    const rawText = await response.text();
    let outer: ApiEnvelope<unknown>;
    try {
      outer = parseJsonSafe<ApiEnvelope<unknown>>(rawText);
    } catch (err) {
      throw new ZaloApiError(
        `Invalid JSON response: ${err instanceof Error ? err.message : String(err)}`,
        null,
        rawText,
      );
    }

    if (outer.error_code !== undefined && outer.error_code !== 0) {
      throw new ZaloApiError(
        outer.error_message || `Zalo API error ${outer.error_code}`,
        outer.error_code,
        outer,
      );
    }

    if (!decryptData || typeof outer.data !== "string") {
      return outer.data as T;
    }

    const decryptedText = decodeAES(this.ctx.secretKey, outer.data, "base64");
    const inner = parseJsonSafe<ApiEnvelope<T>>(decryptedText);
    if (inner.error_code !== undefined && inner.error_code !== 0) {
      throw new ZaloApiError(
        inner.error_message || `Zalo API inner error ${inner.error_code}`,
        inner.error_code,
        inner,
      );
    }
    return inner.data as T;
  }

  async getEncrypted<T = unknown>(
    baseURL: string,
    params: Record<string, unknown> = {},
    opts: EncryptedRequestOptions = {},
  ): Promise<T> {
    const encrypted = this.encryptParams(params);
    const query: Record<string, string | number | boolean | undefined> = {
      ...(opts.extraQuery ?? {}),
      params: encrypted,
      ...(opts.nretry ? { nretry: 0 } : {}),
    };
    const url = this.makeURL(baseURL, query, opts.apiVersion ?? true);
    const res = await this.requestRaw(url, {
      method: "GET",
      kind: opts.imageRequest ? "image" : "xhr",
      headerOverrides: opts.headers,
    });
    return this.resolveEnvelope<T>(res, opts.decryptResponse ?? true);
  }

  async postEncrypted<T = unknown>(
    baseURL: string,
    params: Record<string, unknown> = {},
    opts: EncryptedRequestOptions & { paramsInQuery?: boolean } = {},
  ): Promise<T> {
    const encrypted = this.encryptParams(params);
    const extra: Record<string, string | number | boolean | undefined> = {
      ...(opts.extraQuery ?? {}),
      ...(opts.nretry ? { nretry: 0 } : {}),
    };
    if (opts.paramsInQuery) {
      extra.params = encrypted;
    }
    const url = this.makeURL(baseURL, extra, opts.apiVersion ?? true);
    const res = await this.requestRaw(url, {
      method: "POST",
      kind: "form",
      headerOverrides: opts.headers,
      body: opts.paramsInQuery ? undefined : new URLSearchParams({ params: encrypted }),
    });
    return this.resolveEnvelope<T>(res, opts.decryptResponse ?? true);
  }

  async postMultipart<T = unknown>(
    baseURL: string,
    params: Record<string, unknown>,
    formData: FormData,
    opts: EncryptedRequestOptions = {},
  ): Promise<T> {
    const encrypted = this.encryptParams(params);
    const query: Record<string, string | number | boolean | undefined> = {
      ...(opts.extraQuery ?? {}),
      params: encrypted,
      ...(opts.nretry ? { nretry: 0 } : {}),
    };
    const url = this.makeURL(baseURL, query, opts.apiVersion ?? true);
    const res = await this.requestRaw(url, {
      method: "POST",
      kind: "multipart",
      headerOverrides: opts.headers,
      body: formData,
    });
    return this.resolveEnvelope<T>(res, opts.decryptResponse ?? true);
  }

  /**
   * Direct unencrypted service request (e.g., `getAllGroups` `/api/group/getlg/v4`).
   */
  async getPlain<T = unknown>(
    baseURL: string,
    query: Record<string, string | number | boolean | undefined> = {},
    opts: { apiVersion?: boolean; decryptResponse?: boolean } = {},
  ): Promise<T> {
    const url = this.makeURL(baseURL, query, opts.apiVersion ?? true);
    const res = await this.requestRaw(url, { method: "GET", kind: "xhr" });
    return this.resolveEnvelope<T>(res, opts.decryptResponse ?? true);
  }
}
