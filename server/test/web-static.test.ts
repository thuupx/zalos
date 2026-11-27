import { afterAll, beforeAll, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer, request as httpRequest, type Server } from "node:http";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createWebStaticHandler } from "../src/web_static.ts";

const INDEX_HTML = "<!doctype html><title>zalos</title>";
const WASM_BYTES = new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0]);

let root: string;
let server: Server;
let port: number;

function rawRequest(
  path: string,
  method: "GET" | "HEAD" | "POST" = "GET",
): Promise<{
  status: number;
  headers: Record<string, string | string[] | undefined>;
  body: Buffer;
}> {
  return new Promise((resolve, reject) => {
    const req = httpRequest(
      { hostname: "127.0.0.1", port, path, method },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(Buffer.from(chunk)));
        res.on("end", () =>
          resolve({
            status: res.statusCode ?? 0,
            headers: res.headers,
            body: Buffer.concat(chunks),
          }),
        );
      },
    );
    req.on("error", reject);
    req.end();
  });
}

beforeAll(async () => {
  root = mkdtempSync(join(tmpdir(), "zalos-web-static-"));
  writeFileSync(join(root, "index.html"), INDEX_HTML);
  writeFileSync(join(root, "main.dart.js"), "main()");
  mkdirSync(join(root, "pkg"));
  writeFileSync(join(root, "pkg", "x.wasm"), WASM_BYTES);

  const handler = createWebStaticHandler(root);
  if (handler === null) throw new Error("handler was not created");
  server = createServer(handler);
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  port = (server.address() as AddressInfo).port;
});

afterAll(async () => {
  await new Promise<void>((resolve) => server.close(() => resolve()));
  rmSync(root, { recursive: true, force: true });
});

test("GET / serves index.html with cross-origin isolation headers", async () => {
  const res = await rawRequest("/");
  expect(res.status).toBe(200);
  expect(res.body.toString()).toBe(INDEX_HTML);
  expect(res.headers["cross-origin-opener-policy"]).toBe("same-origin");
  expect(res.headers["cross-origin-embedder-policy"]).toBe("require-corp");
  expect(res.headers["cross-origin-resource-policy"]).toBe("same-origin");
  expect(res.headers["x-frame-options"]).toBe("DENY");
  expect(res.headers["x-content-type-options"]).toBe("nosniff");
  expect(res.headers["referrer-policy"]).toBe("no-referrer");
  expect(res.headers["content-security-policy"]).toBe(
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'none'",
  );
  expect(res.headers["cache-control"]).toBe("no-cache");
});

test("GET /pkg/x.wasm uses the wasm content type", async () => {
  const res = await rawRequest("/pkg/x.wasm");
  expect(res.status).toBe(200);
  expect(res.headers["content-type"]).toBe("application/wasm");
  expect(res.headers["content-length"]).toBe(String(WASM_BYTES.length));
  expect(new Uint8Array(res.body)).toEqual(WASM_BYTES);
});

test("extensionless missing routes fall back to index.html", async () => {
  const res = await rawRequest("/some/route");
  expect(res.status).toBe(200);
  expect(res.body.toString()).toBe(INDEX_HTML);
});

test("missing files with an extension are 404", async () => {
  const res = await rawRequest("/missing.js");
  expect(res.status).toBe(404);
});

test("plain and percent-encoded traversal are 404", async () => {
  for (const path of ["/../etc/passwd", "/%2e%2e/secret", "/%2E%2E/secret"]) {
    const res = await rawRequest(path);
    expect(res.status).toBe(404);
  }
});

test("tunnel API paths are reserved and return 404", async () => {
  const res = await rawRequest("/v1/control");
  expect(res.status).toBe(404);
});

test("POST is rejected with 405 and an Allow header", async () => {
  const res = await rawRequest("/", "POST");
  expect(res.status).toBe(405);
  expect(res.headers.allow).toBe("GET, HEAD");
});

test("HEAD sends headers without a body", async () => {
  const res = await rawRequest("/", "HEAD");
  expect(res.status).toBe(200);
  expect(res.headers["content-length"]).toBe(
    String(Buffer.byteLength(INDEX_HTML)),
  );
  expect(res.body.length).toBe(0);
});

test("missing or incomplete web roots do not create a handler", () => {
  expect(createWebStaticHandler(null)).toBeNull();
  expect(createWebStaticHandler("")).toBeNull();
  const empty = mkdtempSync(join(tmpdir(), "zalos-web-empty-"));
  try {
    expect(createWebStaticHandler(empty)).toBeNull();
  } finally {
    rmSync(empty, { recursive: true, force: true });
  }
});

test("files revalidate and answer If-Modified-Since with 304", async () => {
  const first = await rawRequest("/main.dart.js");
  expect(first.status).toBe(200);
  expect(first.headers["cache-control"]).toBe("no-cache");
  const lastModified = String(first.headers["last-modified"]);
  expect(Number.isNaN(Date.parse(lastModified))).toBe(false);

  const res = await new Promise<number>((resolve, reject) => {
    const req = httpRequest(
      {
        hostname: "127.0.0.1",
        port,
        path: "/main.dart.js",
        headers: { "If-Modified-Since": lastModified },
      },
      (r) => {
        r.resume();
        r.on("end", () => resolve(r.statusCode ?? 0));
      },
    );
    req.on("error", reject);
    req.end();
  });
  expect(res).toBe(304);
});
