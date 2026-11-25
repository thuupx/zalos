import { execSync } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createZalosServer, type ZalosServer } from "../../src/server.ts";

export const MOCK_URL = process.env.ZALOS_MOCK_URL ?? "http://127.0.0.1:7355";
export const E2E = process.env.ZALOS_E2E === "1";

// Brings the mock stack up once per test process (this module is shared
// by every e2e file); false when Docker is unavailable so suites skip.
async function bringUpMock(): Promise<boolean> {
  try {
    execSync("docker compose version", { stdio: "pipe" });
    execSync("docker compose -f ../../../mock/compose.yaml up -d --build --force-recreate", {
      stdio: "pipe",
      cwd: join(import.meta.dir),
      timeout: 240_000,
    });
  } catch {
    return false;
  }
  const deadline = Date.now() + 30_000;
  while (Date.now() < deadline) {
    try {
      const r = await fetch(`${MOCK_URL}/healthz`);
      if (r.ok) break;
    } catch {}
    await sleep(500);
  }
  return true;
}

export const dockerOk = E2E ? await bringUpMock() : false;

export type MockEnv = {
  server: ZalosServer;
  port: number;
  dir: string;
  serverPubHex: string;
  cleanup(): Promise<void>;
};

export async function makeMockEnv(dir?: string): Promise<MockEnv> {
  const dataDir = dir ?? mkdtempSync(join(tmpdir(), "zalos-e2e-"));
  process.env.ZALOS_ZCA_DISPLACED_MS ??= "2000";
  process.env.ZALOS_OA_POLL_MS ??= "800";
  process.env.ZALOS_OA_POLL_IDLE_MS ??= "1200";
  process.env.ZALOS_ZALO_MOCK_URL ??= MOCK_URL;
  const server = createZalosServer({
    dataDir,
    fake: false,
    mockUrl: MOCK_URL,
    allowDev: true,
  });
  const port = await server.tunnel.listen(0, "127.0.0.1");
  await server.ready;
  return {
    server,
    port,
    dir: dataDir,
    serverPubHex: Buffer.from(server.tunnel.serverKey.public).toString("hex"),
    async cleanup() {
      await server.close();
    },
  };
}

export async function mockCtl(
  path: string,
  body?: Record<string, unknown>,
): Promise<Record<string, unknown>> {
  const res = await fetch(`${MOCK_URL}/__mock${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body ?? {}),
  });
  if (!res.ok) throw new Error(`mock ${path}: ${res.status}`);
  return (await res.json()) as Record<string, unknown>;
}

export type JournalEntry = {
  request: {
    method: string;
    url: string;
    headers?: Record<string, string>;
    body?: string;
    bodyAsBase64?: string;
  };
  response: { status: number };
};

export async function journal(): Promise<JournalEntry[]> {
  const res = await fetch(`${MOCK_URL}/__journal`);
  const data = (await res.json()) as { requests: JournalEntry[] };
  return data.requests;
}

// Entries whose decrypted `params` were delivered as a JSON body.
export function journalBodies(entries: JournalEntry[]): {
  entry: JournalEntry;
  params: Record<string, unknown>;
}[] {
  const out: { entry: JournalEntry; params: Record<string, unknown> }[] = [];
  for (const entry of entries) {
    const body = entry.request.body;
    if (body === undefined || body === "") continue;
    try {
      const parsed = JSON.parse(body) as Record<string, unknown>;
      if (
        entry.request.headers?.["x-zalo-params-encrypted"] === "1" ||
        entry.request.headers?.["X-Zalo-Params-Encrypted"] === "1"
      ) {
        out.push({ entry, params: parsed });
      }
    } catch {}
  }
  return out;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

export function mockMsg(overrides: Record<string, unknown>): Record<string, unknown> {
  const ts = Date.now();
  const id = String(ts * 1000 + Math.floor(Math.random() * 1000));
  return {
    actionId: String(ts),
    msgId: id,
    cliMsgId: id,
    msgType: "webchat",
    uidFrom: "777000222",
    idTo: "777000111",
    dName: "Trần Thị Hoa",
    ts: String(ts),
    st: 0,
    at: 0,
    cmd: 0,
    status: 1,
    content: "xin chào",
    propertyExt: { color: -1, size: -1, type: 0, subType: 0, ext: "{}" },
    ttl: 0,
    ...overrides,
  };
}
