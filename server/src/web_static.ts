import { createReadStream, existsSync, realpathSync, statSync } from "node:fs";
import type { IncomingMessage, ServerResponse } from "node:http";
import path from "node:path";

const SECURITY_HEADERS: Record<string, string> = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
  "X-Frame-Options": "DENY",
  "X-Content-Type-Options": "nosniff",
  "Referrer-Policy": "no-referrer",
  "Content-Security-Policy":
    "default-src 'self'; script-src 'self' 'wasm-unsafe-eval' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' ws: wss: https://fonts.gstatic.com; frame-ancestors 'none'; base-uri 'self'",
  "Cross-Origin-Resource-Policy": "same-origin",
};

const CONTENT_TYPES: Record<string, string> = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".mjs": "text/javascript",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".css": "text/css",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".svg": "image/svg+xml",
  ".ico": "image/x-icon",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".map": "application/json",
  ".txt": "text/plain",
  ".webmanifest": "application/manifest+json",
};

function insideRoot(root: string, candidate: string): boolean {
  if (root === path.sep) return candidate.startsWith(path.sep);
  return candidate === root || candidate.startsWith(root + path.sep);
}

function escapesRoot(pathname: string): boolean {
  let depth = 0;
  for (const segment of pathname.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      if (depth === 0) return true;
      depth -= 1;
    } else {
      depth += 1;
    }
  }
  return false;
}

function rawPathname(rawUrl: string): string {
  const end = rawUrl.search(/[?#]/);
  let part = end === -1 ? rawUrl : rawUrl.slice(0, end);
  if (!part.startsWith("/")) {
    const schemeEnd = part.indexOf("://");
    if (schemeEnd !== -1) {
      const slash = part.indexOf("/", schemeEnd + 3);
      part = slash === -1 ? "/" : part.slice(slash);
    }
  }
  return part;
}

function setSecurityHeaders(res: ServerResponse) {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    res.setHeader(name, value);
  }
}

function send404(res: ServerResponse) {
  res.writeHead(404);
  res.end();
}

function serveFile(
  req: IncomingMessage,
  res: ServerResponse,
  filePath: string,
  headOnly: boolean,
): boolean {
  let stat;
  try {
    stat = statSync(filePath);
  } catch {
    return false;
  }
  if (!stat.isFile()) return false;

  const ext = path.extname(filePath).toLowerCase();
  const type = CONTENT_TYPES[ext] ?? "application/octet-stream";
  res.setHeader(
    "Content-Type",
    type.startsWith("text/") || type === "application/json"
      ? `${type}; charset=utf-8`
      : type,
  );
  // Flutter web output is not content-hashed (main.dart.js keeps its name
  // across builds), so every file revalidates; Last-Modified makes that a
  // cheap 304 instead of a full download.
  res.setHeader("Cache-Control", "no-cache");
  const lastModified = new Date(Math.floor(stat.mtimeMs / 1000) * 1000);
  res.setHeader("Last-Modified", lastModified.toUTCString());
  const since = Date.parse(String(req.headers["if-modified-since"] ?? ""));
  if (!Number.isNaN(since) && lastModified.getTime() <= since) {
    res.writeHead(304);
    res.end();
    return true;
  }
  res.setHeader("Content-Length", stat.size);
  res.writeHead(200);
  if (headOnly) {
    res.end();
    return true;
  }

  const stream = createReadStream(filePath);
  stream.on("error", () => res.destroy());
  stream.pipe(res);
  return true;
}

export function createWebStaticHandler(
  rootDir: string | null,
): ((req: IncomingMessage, res: ServerResponse) => void) | null {
  if (rootDir === null || rootDir === "") return null;

  let root: string;
  let indexPath: string;
  try {
    const resolved = path.resolve(rootDir);
    if (!existsSync(path.join(resolved, "index.html"))) return null;
    root = realpathSync(resolved);
    indexPath = realpathSync(path.join(root, "index.html"));
    if (!insideRoot(root, indexPath) || !statSync(indexPath).isFile()) {
      return null;
    }
  } catch {
    return null;
  }

  return (req, res) => {
    setSecurityHeaders(res);

    if (req.method !== "GET" && req.method !== "HEAD") {
      res.setHeader("Allow", "GET, HEAD");
      res.writeHead(405);
      res.end();
      return;
    }

    let pathname: string;
    let rawDecoded: string;
    try {
      const rawUrl = req.url ?? "/";
      rawDecoded = decodeURIComponent(rawPathname(rawUrl));
      pathname = decodeURIComponent(
        new URL(rawUrl, "http://localhost").pathname,
      );
    } catch {
      send404(res);
      return;
    }

    if (
      pathname.includes("\0") ||
      rawDecoded.includes("\0") ||
      pathname.startsWith("/v1/") ||
      escapesRoot(rawDecoded)
    ) {
      send404(res);
      return;
    }
    if (pathname === "/") pathname = "/index.html";

    const resolved = path.resolve(root, `.${pathname}`);
    if (!insideRoot(root, resolved)) {
      send404(res);
      return;
    }

    let realPath: string;
    try {
      realPath = realpathSync(resolved);
    } catch (error) {
      if (
        (error as NodeJS.ErrnoException).code === "ENOENT" &&
        path.extname(pathname) === "" &&
        serveFile(req, res, indexPath, req.method === "HEAD")
      ) {
        return;
      }
      send404(res);
      return;
    }

    if (!insideRoot(root, realPath)) {
      send404(res);
      return;
    }

    if (!serveFile(req, res, realPath, req.method === "HEAD")) send404(res);
  };
}
