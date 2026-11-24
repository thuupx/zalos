// media.fetch: download through the server, cache on disk keyed by
// sha256(url), and refuse internal addresses (SSRF guard).
import {
  closeSync,
  fsyncSync,
  mkdirSync,
  openSync,
  renameSync,
  rmSync,
  existsSync,
  readdirSync,
  readFileSync,
  statfsSync,
  writeFileSync,
} from "node:fs";
import { dirname, join } from "node:path";
import { lookup as dnsLookup } from "node:dns";
import { lookup } from "node:dns/promises";
import http from "node:http";
import https from "node:https";
import ipaddr from "ipaddr.js";
import { RpcError } from "./tunnel/rpc.ts";
import { FileSealer, mediaAad, sha256Hex } from "./vault.ts";
import { isZaloHost, mockGatewayFetch } from "./gateway/mock.ts";

const MAX_DOWNLOAD = 100 * 1024 * 1024;
const MAX_REDIRECTS = 5;
// Per-hop connect+headers budget; whole download capped below.
const CONNECT_TIMEOUT_MS = 20_000;
const OVERALL_TIMEOUT_MS = 120_000;
const MIN_FREE_DISK_BYTES = 128 * 1024 * 1024;

function fsyncPath(path: string) {
  let fd: number | null = null;
  try {
    fd = openSync(path, "r");
    fsyncSync(fd);
  } catch {
    // Best-effort on filesystems/platforms where fsync on read-only fd/dir is unsupported.
  } finally {
    if (fd !== null) {
      try {
        closeSync(fd);
      } catch {}
    }
  }
}

export function assertDiskHeadroom(
  dir: string,
  minFreeBytes = MIN_FREE_DISK_BYTES,
) {
  try {
    const stat = statfsSync(dir);
    const free = Number(stat.bavail) * Number(stat.bsize);
    if (Number.isFinite(free) && free < minFreeBytes) {
      throw new RpcError("resource_exhausted", "insufficient disk space");
    }
  } catch (e) {
    if (e instanceof RpcError) throw e;
    // Ignore statfs unavailability on exotic virtual filesystems.
  }
}

type Addr = ReturnType<typeof ipaddr.process>;
type IPv4Addr = InstanceType<typeof ipaddr.IPv4>;

// Embedded-IPv4 forms (mapped, compatible, 6to4, NAT64, IPv4-translatable)
// are unwrapped to their inner v4 for classification; anything else must
// classify as global unicast to pass.
function embeddedIPv4(a: Addr): IPv4Addr | null {
  if (a.kind() !== "ipv6") return null;
  const parts = (a as InstanceType<typeof ipaddr.IPv6>).parts;
  const last32 = () =>
    new ipaddr.IPv4([parts[6] >> 8, parts[6] & 0xff, parts[7] >> 8, parts[7] & 0xff]);
  // IPv4-compatible ::a.b.c.d (deprecated) and ::a:b (high 96 bits zero).
  if (parts.slice(0, 6).every((p) => p === 0) && (parts[6] !== 0 || parts[7] !== 0)) {
    return last32();
  }
  // RFC6145 IPv4-translatable ::ffff:0:0/96.
  if (parts.slice(0, 4).every((p) => p === 0) && parts[4] === 0xffff && parts[5] === 0) {
    return last32();
  }
  // 6to4 2002:<v4>::/48: the embedded v4 is bits 16..48.
  if (parts[0] === 0x2002) {
    return new ipaddr.IPv4([parts[1] >> 8, parts[1] & 0xff, parts[2] >> 8, parts[2] & 0xff]);
  }
  // NAT64 64:ff9b::<v4>/96.
  if (parts[0] === 0x64 && parts[1] === 0xff9b) {
    return last32();
  }
  return null;
}

// True only for global-unicast addresses. Mapped IPv6 is already folded to
// IPv4 by ipaddr.process; other embedding forms go through embeddedIPv4.
function isPublicAddress(addr: string): boolean {
  let parsed: Addr;
  try {
    // A zone id (%eth0) is a local-interface hint: reject outright.
    if (addr.includes("%")) return false;
    parsed = ipaddr.process(addr);
  } catch {
    return false;
  }
  const v4 = parsed.kind() === "ipv4" ? (parsed as IPv4Addr) : embeddedIPv4(parsed);
  if (v4 !== null) return v4.range() === "unicast";
  // fec0::/10 was site-local (deprecated, RFC 3879); ipaddr.js has no range
  // entry for it and falls back to "unicast", so block it explicitly.
  if (parsed.match(ipaddr.parse("fec0::"), 10)) return false;
  return parsed.range() === "unicast";
}

async function resolveHost(hostname: string): Promise<string[]> {
  try {
    const records = await lookup(hostname, { all: true });
    return records.map((r) => r.address);
  } catch {
    return [];
  }
}

const ALLOWED_CDN_SUFFIXES = [
  "zdn.vn",
  "zadn.vn",
  "zaloapp.com",
  "zalo.me",
  "zingcdn.me",
  "zalo.cloud",
  "zalocdn.com",
];

export function isAllowedEgressHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/\.$/, "");
  if (isZaloHost(h)) return true;
  return ALLOWED_CDN_SUFFIXES.some((s) => h === s || h.endsWith(`.${s}`));
}

export type ResolveFn = (hostname: string) => Promise<string[]>;

// Rejects non-public URLs. A literal host is checked directly; a name is
// resolved and every answer must classify as public. Connection-time pinning
// is additionally enforced inside `pinnedHttpFetch` to prevent DNS rebinding.
export async function assertPublicUrl(
  raw: string,
  opts: {
    allowHttp?: boolean;
    allowlistOnly?: boolean;
    resolve?: ResolveFn;
  } = {},
): Promise<URL> {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new RpcError("bad_request", "invalid url");
  }
  const allowHttp = opts.allowHttp ?? true;
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new RpcError("bad_request", "only http(s) urls");
  }
  if (!allowHttp && url.protocol === "http:") {
    throw new RpcError("forbidden", "only https urls allowed");
  }
  if (url.username !== "" || url.password !== "") {
    throw new RpcError("bad_request", "credentials in url");
  }
  const host = url.hostname.replace(/^\[|\]$/g, "");
  const allowlistOnly =
    opts.allowlistOnly ?? process.env.ZALOS_MEDIA_ALLOWLIST_ONLY === "1";
  if (allowlistOnly && !isAllowedEgressHost(host)) {
    throw new RpcError("forbidden", "host not in egress allowlist");
  }
  // In mock mode Zalo hosts do not resolve on the public DNS; the mock
  // fetch rewires them to the gateway, so skip the resolution check.
  if (
    process.env.ZALOS_ZALO_MOCK_URL !== undefined &&
    isZaloHost(host)
  ) {
    return url;
  }
  let addrs: string[];
  try {
    ipaddr.parse(host);
    addrs = [host];
  } catch {
    addrs = await (opts.resolve ?? resolveHost)(host);
    if (addrs.length === 0) {
      throw new RpcError("forbidden", "host does not resolve");
    }
  }
  for (const addr of addrs) {
    if (!isPublicAddress(addr)) {
      throw new RpcError("forbidden", "address not allowed");
    }
  }
  return url;
}

// Connection-time DNS-pinned HTTP(S) client: resolves DNS inside the socket
// lookup callback, validates EVERY answer with `isPublicAddress`, and connects
// directly to the validated IP while preserving Host header, TLS SNI, and
// certificate verification. Prevents two-stage DNS rebinding TOCTOU.
export function createPinnedLookup(
  resolver: (hostname: string) => Promise<string[]> = resolveHost,
) {
  return (
    hostname: string,
    options: { all?: boolean },
    callback: (
      err: NodeJS.ErrnoException | null,
      address: string | { address: string; family: number }[],
      family?: number,
    ) => void,
  ) => {
    const clean = hostname.replace(/^\[|\]$/g, "");
    const finish = (addrs: string[]) => {
      if (addrs.length === 0) {
        callback(new RpcError("forbidden", "host does not resolve") as NodeJS.ErrnoException, "");
        return;
      }
      for (const a of addrs) {
        if (!isPublicAddress(a)) {
          callback(new RpcError("forbidden", "address not allowed") as NodeJS.ErrnoException, "");
          return;
        }
      }
      const mapped = addrs.map((a) => ({
        address: a,
        family: ipaddr.parse(a).kind() === "ipv6" ? 6 : 4,
      }));
      if (options && options.all) {
        callback(null, mapped);
      } else {
        callback(null, mapped[0]!.address, mapped[0]!.family);
      }
    };
    try {
      ipaddr.parse(clean);
      finish([clean]);
      return;
    } catch {}
    resolver(clean).then(finish, () => {
      // Fallback to native lookup error semantics without leaking internal hostnames.
      void dnsLookup;
      callback(new RpcError("forbidden", "host does not resolve") as NodeJS.ErrnoException, "");
    });
  };
}

export async function pinnedHttpFetch(
  url: URL,
  opts: {
    headers?: Record<string, string>;
    signal?: AbortSignal;
    resolve?: ResolveFn;
  } = {},
): Promise<Response> {
  const isHttps = url.protocol === "https:";
  const mod = isHttps ? https : http;
  const lookupFn = createPinnedLookup(opts.resolve);
  return await new Promise<Response>((resolve, reject) => {
    const req = mod.request(
      {
        protocol: url.protocol,
        hostname: url.hostname,
        port: url.port || (isHttps ? 443 : 80),
        path: `${url.pathname}${url.search}`,
        method: "GET",
        headers: {
          host: url.host,
          ...(opts.headers ?? {}),
        },
        ...(isHttps
          ? { servername: url.hostname, rejectUnauthorized: true }
          : {}),
        lookup: lookupFn as unknown as typeof dnsLookup,
      },
      (res) => {
        const headers = new Headers();
        for (const [k, v] of Object.entries(res.headers)) {
          if (Array.isArray(v)) {
            for (const item of v) headers.append(k, item);
          } else if (v !== undefined) {
            headers.set(k, v);
          }
        }
        const body = new ReadableStream<Uint8Array>({
          start(controller) {
            res.on("data", (chunk: Buffer) => controller.enqueue(new Uint8Array(chunk)));
            res.on("end", () => controller.close());
            res.on("error", (err) => controller.error(err));
          },
          cancel() {
            res.destroy();
          },
        });
        resolve(new Response(body, { status: res.statusCode ?? 500, headers }));
      },
    );
    const onAbort = () => {
      req.destroy(new DOMException("The operation was aborted.", "AbortError"));
    };
    if (opts.signal !== undefined) {
      if (opts.signal.aborted) {
        onAbort();
        return;
      }
      opts.signal.addEventListener("abort", onAbort, { once: true });
      req.on("close", () => opts.signal?.removeEventListener("abort", onAbort));
    }
    req.on("error", (err) => reject(err));
    req.end();
  });
}

async function download(
  raw: string,
  outPath: string,
  headers: Record<string, string>,
): Promise<{ size: number; contentType: string }> {
  let url = raw;
  let sawHttps = false;
  const mockBase = process.env.ZALOS_ZALO_MOCK_URL;
  const strictHttps =
    mockBase === undefined && process.env.ZALOS_ALLOW_INSECURE_MEDIA_HTTP !== "1";
  const overall = AbortSignal.timeout(OVERALL_TIMEOUT_MS);
  for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
    const checked = await assertPublicUrl(url, {
      allowHttp: !sawHttps && !strictHttps,
    });
    if (checked.protocol === "https:") sawHttps = true;
    // Abort if connect+headers takes longer than CONNECT_TIMEOUT_MS.
    const hopCtl = new AbortController();
    const hopTimer = setTimeout(() => hopCtl.abort(), CONNECT_TIMEOUT_MS);
    hopTimer.unref?.();
    let res: Response;
    try {
      const signal = AbortSignal.any([hopCtl.signal, overall]);
      res =
        mockBase !== undefined
          ? await mockGatewayFetch(mockBase)(checked, {
              redirect: "manual",
              headers,
              signal,
            })
          : await pinnedHttpFetch(checked, { headers, signal });
    } catch (e) {
      if (e instanceof RpcError) throw e;
      const name = (e as { name?: string }).name;
      if (name === "AbortError" || name === "TimeoutError") {
        throw new RpcError("timeout", "fetch timed out");
      }
      throw new RpcError("error", `fetch failed: ${(e as Error).message}`);
    } finally {
      clearTimeout(hopTimer);
    }
    if ([301, 302, 303, 307, 308].includes(res.status)) {
      const loc = res.headers.get("location");
      res.body?.cancel();
      if (loc === null) throw new RpcError("error", "redirect without location");
      const next = new URL(loc, checked);
      if (sawHttps && next.protocol === "http:") {
        throw new RpcError("forbidden", "https downgrade refused");
      }
      url = next.toString();
      continue;
    }
    if (!res.ok) {
      res.body?.cancel();
      throw new RpcError("error", `fetch failed: ${res.status}`);
    }
    const len = Number(res.headers.get("content-length") ?? 0);
    if (len > MAX_DOWNLOAD) {
      res.body?.cancel();
      throw new RpcError("error", "too large");
    }
    const writer = Bun.file(outPath).writer();
    let size = 0;
    try {
      if (res.body === null) throw new RpcError("error", "empty body");
      for await (const chunk of res.body as unknown as AsyncIterable<Uint8Array>) {
        size += chunk.length;
        if (size > MAX_DOWNLOAD) throw new RpcError("error", "too large");
        writer.write(chunk);
      }
    } finally {
      await writer.end();
    }
    return {
      size,
      contentType: res.headers.get("content-type") ?? "application/octet-stream",
    };
  }
  throw new RpcError("error", "too many redirects");
}

export type MediaHit = {
  path: string;
  size: number; // plaintext size
  contentType: string;
  sealed: boolean;
};

const CHUNK = 1024 * 1024; // 1 MiB plaintext chunks

function urlKey(rawUrl: string): string {
  return sha256Hex(rawUrl);
}

type CacheMeta = { contentType: string; size: number; sealed: boolean };

// Seal a plaintext file at srcPath into dstPath: header(32) || sealed chunks.
export async function sealFile(
  srcPath: string,
  dstPath: string,
  slot: string,
  hash: string,
  size: number,
  publicKey: Uint8Array,
) {
  const aad = mediaAad(slot, hash, size);
  const sealer = new FileSealer(publicKey, aad);
  const src = Bun.file(srcPath);
  const writer = Bun.file(dstPath).writer();
  writer.write(sealer.header);
  const stream = src.stream();
  const reader = stream.getReader();
  let pending: Uint8Array<ArrayBufferLike> = new Uint8Array(0);
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      pending = concat(pending, value);
      while (pending.length >= CHUNK) {
        writer.write(sealer.sealChunk(pending.subarray(0, CHUNK)));
        pending = pending.subarray(CHUNK);
      }
    }
    if (pending.length > 0) writer.write(sealer.sealChunk(pending));
  } finally {
    reader.releaseLock();
    await writer.end();
  }
}

function concat(a: Uint8Array<ArrayBufferLike>, b: Uint8Array<ArrayBufferLike>): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a);
  out.set(b, a.length);
  return out;
}

type MediaLifecycle = { generation: number; retired: boolean };

const mediaLocks = new Map<string, Promise<void>>();
const mediaLifecycles = new Map<string, MediaLifecycle>();

function mediaStateKey(dataDir: string, slot: string): string {
  return `${dataDir}\0${slot}`;
}

function mediaLifecycle(dataDir: string, slot: string): MediaLifecycle {
  const key = mediaStateKey(dataDir, slot);
  let state = mediaLifecycles.get(key);
  if (state === undefined) {
    state = { generation: 0, retired: false };
    mediaLifecycles.set(key, state);
  }
  return state;
}

function assertMediaActive(
  dataDir: string,
  slot: string,
  generation: number,
) {
  const state = mediaLifecycle(dataDir, slot);
  if (state.retired) throw new RpcError("not_found", "account media removed");
  if (state.generation !== generation) {
    throw new RpcError("conflict", "media cache was cleared during fetch");
  }
}

// Cache hits, vault migration, deletion, and final download publication share
// this per-account queue. Network downloads happen outside it, but must recheck
// the lifecycle and current vault key after acquiring it.
export async function withMediaCacheLock<T>(
  dataDir: string,
  slot: string,
  fn: () => T | Promise<T>,
): Promise<T> {
  const key = mediaStateKey(dataDir, slot);
  const previous = mediaLocks.get(key) ?? Promise.resolve();
  let release!: () => void;
  const hold = new Promise<void>((resolve) => {
    release = resolve;
  });
  const tail = previous.then(() => hold);
  mediaLocks.set(key, tail);
  await previous;
  try {
    return await fn();
  } finally {
    release();
    if (mediaLocks.get(key) === tail) mediaLocks.delete(key);
  }
}

export function enableAccountMedia(dataDir: string, slot: string) {
  const state = mediaLifecycle(dataDir, slot);
  state.retired = false;
  state.generation++;
}

// Invalidate downloads before removing files. `retire` is used for account
// removal and logged-out slots until re-login; thread deletion permits a
// fresh cache. Only the slot's cache and media tmp directory are touched.
export async function clearAccountMedia(
  dataDir: string,
  slot: string,
  opts: { retire?: boolean } = {},
) {
  const state = mediaLifecycle(dataDir, slot);
  state.generation++;
  if (opts.retire === true) state.retired = true;
  await withMediaCacheLock(dataDir, slot, () => {
    rmSync(join(dataDir, "media-cache", slot), {
      recursive: true,
      force: true,
    });
    rmSync(join(dataDir, "tmp", slot), { recursive: true, force: true });
  });
}

export async function deleteMediaObjects(
  dataDir: string,
  slot: string,
  urlHashes: string[],
) {
  if (urlHashes.length === 0) return;
  const cacheDir = join(dataDir, "media-cache", slot);
  await withMediaCacheLock(dataDir, slot, () => {
    if (!existsSync(cacheDir)) return;
    for (const hash of urlHashes) {
      if (!/^[a-f0-9]{64}$/.test(hash)) continue;
      rmSync(join(cacheDir, `${hash}.bin`), { force: true });
      rmSync(join(cacheDir, `${hash}.meta`), { force: true });
      rmSync(join(cacheDir, `${hash}.bin.new`), { force: true });
      rmSync(join(cacheDir, `${hash}.meta.new`), { force: true });
    }
    fsyncPath(cacheDir);
  });
}

async function cacheHit(
  metaPath: string,
  dataPath: string,
): Promise<MediaHit | null> {
  const metaFile = Bun.file(metaPath);
  const dataFile = Bun.file(dataPath);
  if (!(await metaFile.exists()) || !(await dataFile.exists())) return null;
  const meta = (await metaFile.json()) as CacheMeta;
  validateCacheMeta(meta);
  return {
    path: dataPath,
    size: meta.size,
    contentType: meta.contentType,
    sealed: meta.sealed,
  };
}

function validateCacheMeta(meta: CacheMeta) {
  if (
    typeof meta.contentType !== "string" ||
    !Number.isSafeInteger(meta.size) ||
    meta.size < 0 ||
    typeof meta.sealed !== "boolean"
  ) {
    throw new RpcError("error", "invalid media cache metadata");
  }
}

async function writeCacheMeta(metaPath: string, meta: CacheMeta) {
  const staging = `${metaPath}.new`;
  await Bun.write(staging, JSON.stringify(meta));
  fsyncPath(staging);
  renameSync(staging, metaPath);
  fsyncPath(dirname(metaPath));
}

export async function fetchAndCache(
  dataDir: string,
  rawUrl: string,
  opts: {
    slot: string;
    vaultKey?: Uint8Array | null;
    // Server callers supply this so a download that started before vault
    // enablement is sealed with the key that is current at publication time.
    getVaultKey?: () => Uint8Array | null | undefined;
    // Kept for callers that report mock mode; routing itself is driven by
    // gatewayFetch, which the caller supplies only for gateway-backed hosts.
    fake: boolean;
    gatewayFetch?: (url: string) => Promise<{ data: Uint8Array; contentType: string }>;
    gatewayFetchToFile?: (
      url: string,
      outPath: string,
    ) => Promise<{ size: number; contentType: string }>;
    headers?: Record<string, string>;
  },
): Promise<MediaHit> {
  const cacheDir = join(dataDir, "media-cache", opts.slot);
  const tmpDir = join(dataDir, "tmp", opts.slot);
  const key = urlKey(rawUrl);
  const metaPath = join(cacheDir, `${key}.meta`);
  const dataPath = join(cacheDir, `${key}.bin`);
  const generation = mediaLifecycle(dataDir, opts.slot).generation;
  assertMediaActive(dataDir, opts.slot, generation);

  const cached = await withMediaCacheLock(dataDir, opts.slot, async () => {
    assertMediaActive(dataDir, opts.slot, generation);
    mkdirSync(cacheDir, { recursive: true });
    mkdirSync(tmpDir, { recursive: true });
    return cacheHit(metaPath, dataPath);
  });
  if (cached !== null) return cached;

  assertDiskHeadroom(tmpDir);

  // Always stage downloads in the account's tmp directory. Apart from making
  // deletion scoped, this gives sealed and plaintext publication the same
  // atomic-rename behavior.
  const tmp = join(
    tmpDir,
    `dl-${Date.now()}-${Math.floor(Math.random() * 1e9)}`,
  );
  let contentType: string;
  let size: number;
  try {
    // The caller decides routing: a gateway fetch is supplied only for hosts
    // that need the account's cookies, in mock and production alike.
    if (opts.gatewayFetchToFile !== undefined) {
      const res = await opts.gatewayFetchToFile(rawUrl, tmp);
      contentType = res.contentType;
      size = res.size;
    } else if (opts.gatewayFetch !== undefined) {
      const res = await opts.gatewayFetch(rawUrl);
      contentType = res.contentType;
      size = res.data.length;
      await Bun.write(tmp, res.data);
    } else {
      const dl = await download(rawUrl, tmp, opts.headers ?? {});
      contentType = dl.contentType;
      size = dl.size;
    }

    return await withMediaCacheLock(dataDir, opts.slot, async () => {
      assertMediaActive(dataDir, opts.slot, generation);
      // Another request may have populated the URL while this one downloaded.
      const hit = await cacheHit(metaPath, dataPath);
      if (hit !== null) return hit;

      const vaultKey =
        opts.getVaultKey !== undefined
          ? (opts.getVaultKey() ?? null)
          : (opts.vaultKey ?? null);
      const sealed = vaultKey !== null;
      if (vaultKey === null) {
        fsyncPath(tmp);
        renameSync(tmp, dataPath);
        fsyncPath(cacheDir);
      } else {
        const staging = `${dataPath}.new`;
        try {
          await sealFile(tmp, staging, opts.slot, key, size, vaultKey);
          fsyncPath(staging);
          renameSync(staging, dataPath);
          fsyncPath(cacheDir);
        } finally {
          rmSync(staging, { force: true });
        }
      }
      await writeCacheMeta(metaPath, { contentType, size, sealed });
      return { path: dataPath, size, contentType, sealed };
    });
  } finally {
    rmSync(tmp, { force: true });
  }
}

type StagedCacheSeal = {
  dataPath: string;
  metaPath: string;
  backupPath: string;
  sealedPath: string;
  metaStagingPath: string;
  alreadyPublished: boolean;
};

// Stage every ciphertext before `beforePublish` installs the key and seals the
// SQLite rows in one transaction. Files are then switched with atomic renames.
// A crash between the database and filesystem phases is resumable: the backup
// and staging suffixes distinguish sealed data from the remaining plaintext,
// and a same-key call or startup invokes this function again.
export function sealMediaCache(
  dataDir: string,
  slot: string,
  publicKey: Uint8Array,
  beforePublish: () => void = () => {},
) {
  const cacheDir = join(dataDir, "media-cache", slot);
  if (existsSync(cacheDir)) {
    const staged: StagedCacheSeal[] = [];
    try {
      for (const name of readdirSync(cacheDir)) {
        if (!name.endsWith(".meta")) continue;
        const metaPath = join(cacheDir, name);
        const meta = JSON.parse(readFileSync(metaPath, "utf-8")) as CacheMeta;
        validateCacheMeta(meta);
        const hash = name.replace(/\.meta$/, "");
        const dataPath = join(cacheDir, `${hash}.bin`);
        const backupPath = `${dataPath}.plaintext`;
        const sealedPath = `${dataPath}.sealing`;
        const metaStagingPath = `${metaPath}.sealing`;

        if (meta.sealed) {
          // A prior attempt may have committed its metadata but not yet
          // removed the plaintext backup.
          if (existsSync(dataPath)) rmSync(backupPath, { force: true });
          continue;
        }
        if (!existsSync(dataPath) && existsSync(backupPath)) {
          // The process stopped after moving plaintext aside but before the
          // sealed rename. Restore it so staging can be repeated safely.
          renameSync(backupPath, dataPath);
        }
        if (!existsSync(dataPath)) continue;

        const alreadyPublished = existsSync(backupPath);
        if (!alreadyPublished) {
          sealFileSync(dataPath, sealedPath, slot, hash, meta.size, publicKey);
          fsyncPath(sealedPath);
        }
        // If both paths exist while metadata says plaintext, the previous
        // attempt completed the sealed rename but not the metadata rename.
        writeFileSync(
          metaStagingPath,
          JSON.stringify({ ...meta, sealed: true }),
        );
        fsyncPath(metaStagingPath);
        staged.push({
          dataPath,
          metaPath,
          backupPath,
          sealedPath,
          metaStagingPath,
          alreadyPublished,
        });
      }
    } catch (error) {
      for (const name of readdirSync(cacheDir)) {
        if (name.endsWith(".sealing")) {
          rmSync(join(cacheDir, name), { force: true });
        }
      }
      throw error;
    }

    // No account key is installed until every cache object has staged
    // successfully. If this callback throws, existing live files are intact.
    beforePublish();

    for (const item of staged) {
      if (!item.alreadyPublished) {
        renameSync(item.dataPath, item.backupPath);
        renameSync(item.sealedPath, item.dataPath);
      }
      renameSync(item.metaStagingPath, item.metaPath);
      rmSync(item.backupPath, { force: true });
    }
    fsyncPath(cacheDir);
    return;
  }
  beforePublish();
}

function sealFileSync(
  srcPath: string,
  dstPath: string,
  slot: string,
  hash: string,
  size: number,
  publicKey: Uint8Array,
) {
  const aad = mediaAad(slot, hash, size);
  const sealer = new FileSealer(publicKey, aad);
  const data = readFileSync(srcPath);
  const out: Uint8Array[] = [sealer.header];
  for (let off = 0; off < data.length; off += CHUNK) {
    out.push(sealer.sealChunk(data.subarray(off, off + CHUNK)));
  }
  writeFileSync(dstPath, Buffer.concat(out.map((u) => Buffer.from(u))));
}
