// zalo-mock gateway: the transport layer in front of WireMock.
//
// HTTP: requests arrive as http://<gw>/<original-host>/<path>?<query>.
// Encrypted `params` are decrypted (login key for /api/login/*, session
// key otherwise) and forwarded to WireMock as a JSON body on the same
// method and path; the `data` field of the WireMock response is
// re-encrypted the way the real server does. Unencrypted endpoints pass
// through with headers and cookies intact.
//
// WS: the url advertised in zpw_ws. Sends the cipher-key frame, serves
// old-message/old-reaction requests from the in-memory store seeded by
// /__mock, and pushes events driven by the /__mock control API.
import {
  sessionEncrypt,
  sessionDecrypt,
  loginEncryptKey,
  loginEncrypt,
  loginDecrypt,
} from "./crypto.ts";
import {
  createPhaseDState,
  phaseDResponse,
  phaseDStateSnapshot,
} from "./phased.ts";

const PORT = Number(process.env.MOCK_PORT ?? 7355);
const WIREMOCK = process.env.WIREMOCK_URL ?? "http://wiremock:8080";
const SESSION_KEY =
  process.env.MOCK_SESSION_KEY ?? "MDEyMzQ1Njc4OUFCQ0RFRg==";
// Base url the zpw_ws urls are rewritten to, derived from the Host the
// client used to reach this gateway: host-side zalos and e2e get
// ws://127.0.0.1:7355, a zalos container on the compose network gets
// ws://gateway:7355. MOCK_WS_BASE overrides it (e.g. behind a proxy).
function wsBase(req: Request): string {
  if (process.env.MOCK_WS_BASE) return process.env.MOCK_WS_BASE;
  return `ws://${req.headers.get("host") ?? new URL(req.url).host}`;
}

// /__mock/cookie/rotate: while set, every proxied response carries this
// Set-Cookie, the way Zalo refreshes session cookies on ordinary calls.
let rotatedCookie: string | null = null;

type Json = Record<string, unknown>;

function wsFrame(cmd: number, subCmd: number, payload: unknown): Uint8Array {
  const body = new TextEncoder().encode(JSON.stringify(payload));
  const out = new Uint8Array(4 + body.length);
  out[0] = 1;
  out[1] = cmd & 0xff;
  out[2] = (cmd >> 8) & 0xff;
  out[3] = subCmd;
  out.set(body, 4);
  return out;
}

// Events are sent with encrypt=0: decodeEventData accepts a plain JSON
// string and skips all crypto, which keeps the mock readable. The inner
// document is itself wrapped in {data: ...}; the listener reads .data of
// the decoded object.
function eventFrame(cmd: number, data: unknown): Uint8Array {
  return wsFrame(cmd, 0, { data: JSON.stringify({ data }), encrypt: 0 });
}

const sockets = new Set<{
  send(d: Uint8Array | string): void;
  close(c?: number): void;
  terminate?: () => void;
}>();
function broadcast(frame: Uint8Array) {
  for (const s of sockets) {
    try {
      s.send(frame);
    } catch {}
  }
}

// History served on cmd 510/511/610/611. Seeded through the control API.
const oldStore = {
  userMsgs: [] as Json[],
  groupMsgs: [] as Json[],
  userReacts: [] as Json[],
  groupReacts: [] as Json[],
};

// ---- OA (Official Account) mock ----
// The OA OpenAPI is unencrypted JSON with an access_token header. Stateful
// pieces live here: the inbox that listrecentchat/conversation read, the
// single-use refresh-token rotation, and fault flags. Stateless stubs
// (profile, user detail, uploads, message send) are WireMock mappings in
// 60-oa.json so their requests land in the journal.
const oaState = {
  inbox: [] as Json[],
  accessToken: "oa-at-1",
  refreshToken: "oa-rt-1",
  rotateCount: 1,
  // /__mock/oa/expire-token: marks the current access token dead; openapi
  // calls carrying it get -216 while other tokens stay valid.
  deadTokens: new Set<string>(),
  windowExpired: new Set<string>(),
  seq: 0,
};

// ---- Phase D conversation mock ----
// Hidden/archived conversations, labels, auto-delete and linked devices
// need state (versioned label writes, mutating lists), so the gateway
// answers them from memory instead of a static WireMock stub.
let phaseD = createPhaseDState();

function oaMessage(body: Json): Json {
  const ts = Date.now();
  return {
    message_id: `oam-${ts}-${++oaState.seq}`,
    user_id: String(body.userId ?? body.user_id ?? ""),
    display_name: String(body.displayName ?? body.display_name ?? ""),
    type: String(body.type ?? "text"),
    text: body.text,
    url: body.url,
    thumb: body.thumb,
    file_name: body.fileName ?? body.file_name,
    time: ts,
    src: 0,
  };
}

function oaPage(items: Json[], dataParam: string | null): Json {
  const q = JSON.parse(dataParam ?? "{}") as {
    offset?: number;
    count?: number;
    user_id?: string;
  };
  let rows = items;
  if (q.user_id !== undefined) {
    rows = items.filter((i) => String(i.user_id) === q.user_id);
  }
  rows = [...rows].sort((a, b) => Number(b.time) - Number(a.time));
  const offset = Number(q.offset ?? 0);
  const count = Number(q.count ?? 10);
  return {
    error: 0,
    message: "",
    data: { data: rows.slice(offset, offset + count) },
  };
}

// Handles OA endpoints that must be stateful or dynamic; returns null for
// anything WireMock should answer.
async function oaHttp(req: Request, host: string, rest: string): Promise<Response | null> {
  const json = (o: unknown, status = 200) =>
    Response.json(o as Json, { status });

  if (host === "oauth.zaloapp.com" && rest === "/v4/oa/access_token") {
    const form = new URLSearchParams(await req.text());
    const rt = form.get("refresh_token") ?? "";
    // Refresh tokens are single use: replaying an old one is rejected.
    if (rt !== oaState.refreshToken) {
      console.log(`[mock] oa refresh rejected rt=${rt} want=${oaState.refreshToken}`);
      return json({ error: -216, error_name: "invalid refresh token" });
    }
    console.log(`[mock] oa refresh ok rt=${rt} -> oa-rt-${oaState.rotateCount + 1}`);
    oaState.rotateCount++;
    oaState.accessToken = `oa-at-${oaState.rotateCount}`;
    oaState.refreshToken = `oa-rt-${oaState.rotateCount}`;
    return json({
      access_token: oaState.accessToken,
      refresh_token: oaState.refreshToken,
      expires_in: "90000",
    });
  }

  if (host !== "openapi.zalo.me") return null;

  // Bun's HTTP server drops underscored headers, so the gateway also
  // sends the token as a query param; accept either.
  const bearer =
    req.headers.get("access_token") ??
    new URL(req.url).searchParams.get("access_token") ??
    "";
  if (oaState.deadTokens.has(bearer)) {
    return json({ error: -216, message: "access token expired" });
  }

  if (rest === "/v2.0/oa/listrecentchat" || rest === "/v2.0/oa/conversation") {
    const url = new URL(req.url);
    const q = new URLSearchParams(url.search);
    return json(oaPage(oaState.inbox, q.get("data")));
  }

  if (rest === "/v3.0/oa/message/cs" && req.method === "POST") {
    const body = (await req.json().catch(() => ({}))) as {
      recipient?: { user_id?: string };
      message?: { text?: string; attachment?: { payload?: { elements?: { media_type?: string }[] } } };
    };
    const userId = String(body.recipient?.user_id ?? "");
    if (oaState.windowExpired.has(userId)) {
      return json({ error: -230, message: "user not interacted recently" });
    }
    // Journal the send via the WireMock stub, then mirror it into the
    // inbox as an outbound message (src 1) the next poll can see.
    const res = await proxy(
      new Request(req.url, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      }),
      new URL(req.url),
    );
    const parsed = (await res.json().catch(() => ({}))) as {
      error?: number;
      data?: { message_id?: string };
    };
    if ((parsed.error ?? 0) === 0 && parsed.data?.message_id !== undefined) {
      const el = body.message?.attachment?.payload?.elements?.[0];
      oaState.inbox.push({
        message_id: String(parsed.data.message_id),
        user_id: userId,
        type: el?.media_type ?? (body.message?.text !== undefined ? "text" : "text"),
        text: body.message?.text,
        url: "",
        time: Date.now(),
        src: 1,
      });
    }
    return Response.json(parsed, { status: 200 });
  }

  return null;
}

async function wmFetch(path: string, init?: RequestInit): Promise<Response> {
  return fetch(`${WIREMOCK}${path}`, init);
}

async function scenario(name: string, state: string): Promise<void> {
  await wmFetch(`/__admin/scenarios/${encodeURIComponent(name)}/state`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ state }),
  });
}

function msgRecord(body: Json): Json {
  const ts = Date.now();
  return {
    actionId: String(ts),
    msgId: body.msgId !== undefined ? String(body.msgId) : String(ts),
    cliMsgId: body.cliMsgId !== undefined ? String(body.cliMsgId) : String(ts),
    msgType: body.msgType ?? "webchat",
    uidFrom: String(body.uidFrom ?? "0"),
    idTo: String(body.idTo ?? ""),
    dName: body.dName ?? "",
    ts: body.ts !== undefined ? String(body.ts) : String(ts),
    st: 0,
    at: 0,
    cmd: 0,
    status: 1,
    content: body.content ?? "",
    ...(body.quote !== undefined ? { quote: body.quote } : {}),
    ...(body.mentions !== undefined ? { mentions: body.mentions } : {}),
    propertyExt: { color: -1, size: -1, type: 0, subType: 0, ext: "{}" },
    ttl: body.ttl !== undefined ? Number(body.ttl) : 0,
  };
}

function fileDone(fileId: string, url: string) {
  // A beat later, the same way the real backend reports completed
  // asyncfile uploads over the listener.
  setTimeout(() => {
    broadcast(
      eventFrame(601, {
        controls: [
          { content: { act_type: "file_done", fileId, data: { url } } },
        ],
      }),
    );
  }, 250);
}

// One realistic message per structured kind, plus a ttl text and an
// unknown payload, so a dev build can exercise every bubble without a
// real account. Injected through the same listener frame as live traffic.
function structuredFixtures(threadId: string, isGroup: boolean): Json[] {
  const media = "http://mock-media.zdn.vn";
  return [
    {
      msgType: "chat.recommended",
      content: {
        title: "Trần Thị Hoa",
        thumb: `${media}/avatars/u777000222.jpg`,
        href: "https://zalo.me/777000222",
        description: JSON.stringify({
          phone: "0900000000",
          qrCodeUrl: `${media}/qr/hoa.png`,
        }),
      },
    },
    {
      msgType: "chat.bankcard",
      content: {
        params: JSON.stringify({
          binBank: 970436,
          numAccBank: "0123456789",
          nameAccBank: "NGUYEN VAN A",
          bankName: "Vietcombank",
        }),
      },
    },
    {
      msgType: "chat.location.new",
      content: {
        title: "Quán cà phê",
        params: JSON.stringify({
          lat: 10.7769,
          lng: 106.7009,
          address: "Quận 1, TP. Hồ Chí Minh",
        }),
      },
    },
    {
      msgType: "group.poll",
      content: {
        title: "Chọn quán",
        params: JSON.stringify({
          poll_id: 501,
          question: "Tối nay ăn gì?",
          options: [
            { option_id: 1, content: "Phở", votes: 2, voted: true },
            { option_id: 2, content: "Bún", votes: 1, voted: false },
          ],
          closed: false,
          allow_multi_choices: false,
          num_vote: 3,
        }),
      },
    },
    {
      msgType: "group.note",
      content: {
        params: JSON.stringify({
          noteId: "note-1",
          title: "Ghi chú nhóm",
          extra: "Nhớ mang laptop",
          pinAct: 1,
        }),
      },
    },
    {
      msgType: "group.reminder",
      content: {
        params: JSON.stringify({
          reminderId: "rem-1",
          title: "Họp nhóm",
          startTime: Date.now() + 3_600_000,
          repeat: 0,
          emoji: "⏰",
        }),
      },
    },
    {
      msgType: "chat.call",
      content: {
        params: JSON.stringify({
          callType: "video",
          callStatus: "missed",
          duration: 0,
        }),
      },
    },
    {
      msgType: "chat.doodle",
      content: {
        params: JSON.stringify({
          hdUrl: `${media}/doodle/hd.png`,
          thumbUrl: `${media}/doodle/thumb.png`,
          width: 800,
          height: 600,
        }),
      },
    },
    {
      msgType: "chat.album",
      content: {
        params: JSON.stringify({
          albumId: "album-1",
          items: [
            { hdUrl: `${media}/album/1-hd.jpg`, thumbUrl: `${media}/album/1-thumb.jpg`, width: 640, height: 480 },
            { hdUrl: `${media}/album/2-hd.jpg`, thumbUrl: `${media}/album/2-thumb.jpg`, width: 640, height: 480 },
          ],
        }),
      },
    },
    {
      msgType: "chat.todo",
      content: {
        params: JSON.stringify({
          todoId: "todo-1",
          item: {
            content: "Mua sữa",
            items: [
              { text: "Mua sữa", done: false },
              { text: "Mua bánh", done: true },
            ],
          },
        }),
      },
    },
    { msgType: "webchat", content: "Tin nhắn tự hủy", ttl: 60_000 },
    { msgType: "chat.mystery", content: { foo: "bar" } },
    // Malformed structured payloads must degrade to "other", never drop.
    {
      msgType: "chat.bankcard",
      content: { params: JSON.stringify({ binBank: 970436 }) },
    },
    {
      msgType: "chat.location.new",
      content: { params: JSON.stringify({ lat: 10.5 }) },
    },
  ].map((f, i) => ({
    type: isGroup ? "group" : "user",
    uidFrom: "777000222",
    idTo: threadId,
    dName: "Trần Thị Hoa",
    ts: Date.now() + i,
    ...f,
  }));
}

async function controlApi(req: Request, path: string): Promise<Response> {
  const body = (await req.json().catch(() => ({}))) as Json;
  const json = (o: unknown, status = 200) =>
    Response.json(o as Json, { status });

  switch (path) {
    case "/events/message": {
      const isGroup = body.type === "group";
      const rec = msgRecord(body);
      broadcast(
        eventFrame(isGroup ? 521 : 501, {
          [isGroup ? "groupMsgs" : "msgs"]: [rec],
        }),
      );
      return json({ ok: true, msgId: rec.msgId, cliMsgId: rec.cliMsgId });
    }
    case "/phased/messages": {
      // One fixture per structured incoming kind, plus ttl and unknown.
      const threadId = String(body.threadId ?? "777000222");
      const isGroup = body.type === "group";
      const fixtures = structuredFixtures(threadId, isGroup);
      for (const f of fixtures) {
        broadcast(
          eventFrame(isGroup ? 521 : 501, {
            [isGroup ? "groupMsgs" : "msgs"]: [msgRecord(f)],
          }),
        );
      }
      return json({ ok: true, count: fixtures.length });
    }
    case "/events/undo": {
      const isGroup = body.type === "group";
      const rec = msgRecord({
        ...body,
        content: {
          deleteMsg: 1,
          globalMsgId: Number(body.msgId),
          cliMsgId: Number(body.cliMsgId ?? body.msgId),
          srcId: Number(body.srcId ?? 0),
          destId: 0,
        },
      });
      broadcast(
        eventFrame(isGroup ? 521 : 501, {
          [isGroup ? "groupMsgs" : "msgs"]: [rec],
        }),
      );
      return json({ ok: true });
    }
    case "/events/reaction": {
      const isGroup = body.isGroup === true;
      const content = JSON.stringify({
        rMsg: [
          {
            gMsgID: String(body.msgId ?? ""),
            cMsgID: String(body.cliMsgId ?? ""),
            msgType: body.msgTypeId ?? 1,
          },
        ],
        rIcon: body.icon ?? "",
        rType: 3,
        source: 6,
      });
      const react = msgRecord({ ...body, content });
      broadcast(
        eventFrame(612, {
          reacts: isGroup ? [] : [react],
          reactGroups: isGroup ? [react] : [],
        }),
      );
      return json({ ok: true });
    }
    case "/events/typing": {
      const group = body.type === "group";
      const data = group
        ? `"uid":"${body.uid}","gid":"${body.threadId}","ts":"${Date.now()}","isPC":0`
        : `"uid":"${body.uid ?? body.threadId}","ts":"${Date.now()}","isPC":0`;
      broadcast(
        eventFrame(602, {
          actions: [
            { act_type: "typing", act: group ? "gtyping" : "typing", data },
          ],
        }),
      );
      return json({ ok: true });
    }
    case "/events/seen": {
      if (body.type === "group") {
        broadcast(
          eventFrame(522, {
            delivereds: [],
            groupSeens: ((body.userIds as string[]) ?? []).map((uid) => ({
              msgId: String(body.msgId ?? ""),
              groupId: String(body.threadId),
              seenUids: [uid],
            })),
          }),
        );
      } else {
        broadcast(
          eventFrame(502, {
            delivereds: [],
            seens: [
              {
                idTo: String(body.uidFrom ?? body.threadId),
                msgId: String(body.msgId ?? ""),
                realMsgId: String(body.msgId ?? ""),
              },
            ],
          }),
        );
      }
      return json({ ok: true });
    }
    case "/events/delivered": {
      const group = body.type === "group";
      const d = {
        msgId: String(body.msgId ?? ""),
        realMsgId: String(body.msgId ?? ""),
        seen: 0,
        deliveredUids: (body.userIds as string[]) ?? [],
        seenUids: [],
        mSTs: Date.now(),
        ...(group ? { groupId: String(body.threadId) } : {}),
      };
      broadcast(
        eventFrame(group ? 522 : 502, {
          delivereds: [d],
          ...(group ? { groupSeens: [] } : { seens: [] }),
        }),
      );
      return json({ ok: true });
    }
    case "/events/group": {
      broadcast(
        eventFrame(601, {
          controls: [
            {
              content: {
                act_type: "group",
                act: body.act ?? "update",
                data: body.data ?? {},
              },
            },
          ],
        }),
      );
      return json({ ok: true });
    }
    case "/events/friend": {
      broadcast(
        eventFrame(601, {
          controls: [
            {
              content: {
                act_type: "fr",
                act: body.act ?? "req_v2",
                data: body.data ?? {},
              },
            },
          ],
        }),
      );
      return json({ ok: true });
    }
    case "/old-messages/user":
    case "/old-messages/group": {
      const store =
        path === "/old-messages/user" ? oldStore.userMsgs : oldStore.groupMsgs;
      for (const m of (body.msgs as Json[]) ?? []) store.push(m);
      return json({ ok: true, count: store.length });
    }
    case "/old-reactions/user":
    case "/old-reactions/group": {
      const store =
        path === "/old-reactions/user"
          ? oldStore.userReacts
          : oldStore.groupReacts;
      for (const r of (body.reacts as Json[]) ?? []) store.push(r);
      return json({ ok: true, count: store.length });
    }
    case "/qr/scan":
      await scenario("zalo-qr", "scanned");
      return json({ ok: true });
    case "/qr/confirm":
      await scenario("zalo-qr", "confirmed");
      return json({ ok: true });
    case "/qr/decline":
      await scenario("zalo-qr", "declined");
      return json({ ok: true });
    case "/qr/expire":
      await scenario("zalo-qr", "expired");
      return json({ ok: true });
    case "/cookie/rotate": {
      const name = String(body.name ?? "zpw_sek");
      const value = String(body.value ?? "");
      if (!/^[\w-]+$/.test(name) || !/^[\w-]+$/.test(value)) {
        return json({ error: "name and value must be [A-Za-z0-9_-]+" }, 400);
      }
      rotatedCookie = `${name}=${value}; Domain=zalo.me; Path=/`;
      return json({ ok: true });
    }
    case "/ws/kick": {
      if (body.reason === "abnormal") {
        for (const s of sockets) {
          try {
            s.terminate?.();
            s.close(1006);
          } catch {}
        }
      } else {
        const code = Number(body.reason ?? 3000) || 3000;
        for (const s of sockets) s.close(code);
      }
      console.log(`[mock] ws/kick reason=${String(body.reason)} sockets=${sockets.size}`);
      return json({ ok: true, kicked: sockets.size });
    }
    case "/oa/events/message": {
      const rec = oaMessage(body);
      oaState.inbox.push(rec);
      return json({ ok: true, messageId: rec.message_id });
    }
    case "/oa/expire-token": {
      // Default: the token the mock last issued; tests may name the one
      // the client currently holds.
      oaState.deadTokens.add(
        String(body.accessToken ?? oaState.accessToken),
      );
      return json({ ok: true });
    }
    case "/oa/set-window-expired": {
      const uid = String(body.userId ?? body.user_id ?? "");
      if (uid !== "") oaState.windowExpired.add(uid);
      return json({ ok: true });
    }
    case "/oa/state": {
      return json({
        inbox: oaState.inbox.length,
        accessToken: oaState.accessToken,
        refreshToken: oaState.refreshToken,
      });
    }
    case "/phased/state": {
      // Sanitized: no PIN hash, no device identity/signature blobs.
      return json(phaseDStateSnapshot(phaseD));
    }
    case "/phased/reset": {
      phaseD = createPhaseDState();
      return json({ ok: true });
    }
    case "/reset": {
      await scenario("zalo-qr", "Started");
      await wmFetch("/__admin/requests", { method: "DELETE" });
      oldStore.userMsgs.length = 0;
      oldStore.groupMsgs.length = 0;
      oldStore.userReacts.length = 0;
      oldStore.groupReacts.length = 0;
      oaState.inbox.length = 0;
      oaState.deadTokens.clear();
      oaState.windowExpired.clear();
      oaState.accessToken = "oa-at-1";
      oaState.refreshToken = "oa-rt-1";
      oaState.rotateCount = 1;
      rotatedCookie = null;
      phaseD = createPhaseDState();
      return json({ ok: true });
    }
    default:
      return json({ error: `unknown control path ${path}` }, 404);
  }
}

// Forwards a (possibly encrypted) request to WireMock and re-encrypts the
// `data` field of the response when the request carried encrypted params.
async function proxy(req: Request, url: URL): Promise<Response> {
  const host = url.pathname.split("/")[1];
  const rest = url.pathname.slice(host.length + 1) || "/";
  const isLoginApi = rest.startsWith("/api/login/");

  let secretParam: string | null = null;
  const query = new URLSearchParams(url.search);
  if (query.has("params")) {
    secretParam = query.get("params");
    query.delete("params");
  }
  const contentType = req.headers.get("content-type") ?? "";
  let bodyBytes = new Uint8Array(await req.arrayBuffer());
  if (secretParam === null && contentType.includes("x-www-form-urlencoded")) {
    const form = new URLSearchParams(new TextDecoder().decode(bodyBytes));
    if (form.has("params")) {
      secretParam = form.get("params");
      form.delete("params");
      bodyBytes = new TextEncoder().encode(form.toString());
    }
  }

  const headers = new Headers(req.headers);
  headers.delete("host");
  headers.delete("content-length");
  // Forwarded content-encoding would come back compressed while we read
  // raw bytes; identity keeps the proxy text-safe. Bun adds its own
  // accept-encoding when the header is absent, so pin it explicitly.
  headers.set("accept-encoding", "identity");
  const init: RequestInit = {
    method: req.method,
    headers,
    redirect: "manual",
  };

  let decryptedParams: string | null = null;
  if (secretParam !== null) {
    try {
      decryptedParams = isLoginApi
        ? loginDecrypt(
            loginEncryptKey(
              query.get("zcid") ?? "",
              query.get("zcid_ext") ?? "",
            ),
            secretParam,
          )
        : sessionDecrypt(SESSION_KEY, secretParam);
    } catch (e) {
      return new Response(
        JSON.stringify({ error: `param decrypt failed: ${String(e)}` }),
        { status: 400 },
      );
    }
  }

  // Stubs can template on individual decrypted fields via mock_<name>
  // query params (for values that only exist inside encrypted params).
  if (decryptedParams !== null) {
    try {
      const obj = JSON.parse(decryptedParams) as Record<string, unknown>;
      for (const [k, v] of Object.entries(obj)) {
        if (["string", "number", "boolean"].includes(typeof v)) {
          query.set(`mock_${k}`, String(v));
        }
      }
    } catch {}
  }

  // Phase D conversation endpoints are stateful; answer them from the
  // mock state instead of a static stub. The response is encrypted the
  // same way WireMock-backed responses are.
  if (decryptedParams !== null && !isLoginApi) {
    let parsedParams: Json | null = null;
    try {
      const obj = JSON.parse(decryptedParams) as unknown;
      if (obj !== null && typeof obj === "object" && !Array.isArray(obj)) {
        parsedParams = obj as Json;
      }
    } catch {}
    const phased = phaseDResponse(phaseD, req.method, rest, parsedParams);
    if (phased !== null) {
      const inner = phased.ok
        ? { error_code: 0, error_message: "Success", data: phased.data }
        : { error_code: phased.code, error_message: phased.message };
      const headers = new Headers({ "content-type": "application/json" });
      if (rotatedCookie !== null) headers.append("set-cookie", rotatedCookie);
      return new Response(
        JSON.stringify({
          error_code: 0,
          error_message: "Success",
          data: sessionEncrypt(SESSION_KEY, JSON.stringify(inner)),
        }),
        { status: 200, headers },
      );
    }
  }

  // Deliver the decrypted params so stubs and the journal can assert on
  // them in plaintext: JSON body normally; a header for multipart.
  const canHaveBody = req.method !== "GET" && req.method !== "HEAD";
  if (decryptedParams !== null) {
    headers.set("x-zalo-params-encrypted", "1");
    if (!canHaveBody || contentType.includes("multipart/form-data")) {
      headers.set("x-zalo-decrypted-params", decryptedParams);
      if (canHaveBody) init.body = bodyBytes;
    } else {
      headers.set("content-type", "application/json");
      init.body = decryptedParams;
    }
  } else if (canHaveBody && bodyBytes.byteLength > 0) {
    init.body = bodyBytes;
  }

  const qs = query.toString();
  const res = await wmFetch(
    `/${host}${rest}${qs === "" ? "" : `?${qs}`}`,
    init,
  );
  const resHeaders = new Headers(res.headers);
  resHeaders.delete("content-length");
  resHeaders.delete("content-encoding");
  if (rotatedCookie !== null) resHeaders.append("set-cookie", rotatedCookie);
  let resBody = new Uint8Array(await res.arrayBuffer());
  const ce = res.headers.get("content-encoding");
  if (resBody.length > 2 && resBody[0] === 0x1f && resBody[1] === 0x8b) {
    resBody = Bun.gunzipSync(resBody);
  } else if (ce === "br") {
    resBody = new Uint8Array(brotliDecompressSync(resBody));
  } else if (ce === "deflate") {
    resBody = new Uint8Array(inflateSync(resBody));
  } else if (ce === "zstd") {
    resBody = Bun.zstdDecompressSync(resBody);
  }
  if (ce !== null) resHeaders.delete("content-encoding");

  // zca-js decrypts every /api/ response, including calls that carry no
  // params (e.g. getAllGroups); only the login api answers in plaintext.
  const encryptedApi = !isLoginApi && rest.startsWith("/api/") && query.has("zpw_ver");
  if (secretParam === null && !encryptedApi) {
    return new Response(resBody, { status: res.status, headers: resHeaders });
  }

  try {
    const parsed = JSON.parse(new TextDecoder().decode(resBody)) as Json & {
      data?: unknown;
    };
    if (
      (parsed.error_code !== undefined && parsed.error_code !== 0) ||
      parsed.data === undefined
    ) {
      return new Response(resBody, { status: res.status, headers: resHeaders });
    }

    // The WS endpoints the client should connect to live in this
    // deployment, not in the static stub.
    if (rest.includes("getLoginInfo")) {
      const loginData = parsed.data as { data?: { zpw_ws?: unknown } };
      if (loginData.data !== undefined) {
        const base = wsBase(req);
        loginData.data.zpw_ws = [`${base}/ws1`, `${base}/ws2`];
      }
    }

    // Async upload finished: the real backend reports file_done over the
    // listener; emit it from the ids the stub returned.
    const inner = (parsed.data as Json).data as Json | undefined;
    if (
      rest.endsWith("/asyncfile/upload") &&
      inner !== undefined &&
      inner.fileId !== undefined
    ) {
      fileDone(
        String(inner.fileId),
        String(inner.fileUrl ?? "http://mock-media.zdn.vn/files/upload.bin"),
      );
    }

    const enc = isLoginApi
      ? loginEncrypt(
          loginEncryptKey(
            query.get("zcid") ?? "",
            query.get("zcid_ext") ?? "",
          ),
          JSON.stringify(parsed.data),
        )
      : sessionEncrypt(SESSION_KEY, JSON.stringify(parsed.data));
    resHeaders.set("content-type", "application/json");
    return new Response(
      JSON.stringify({
        error_code: 0,
        error_message: parsed.error_message ?? "Success",
        data: enc,
      }),
      { status: res.status, headers: resHeaders },
    );
  } catch (e) {
    console.log(
      `[mock] re-encrypt failed ${req.method} ${url.pathname}: ${String(e)} body=${new TextDecoder().decode(resBody).slice(0, 200)}`,
    );
    return new Response(
      JSON.stringify({ error: `re-encrypt failed: ${String(e)}` }),
      { status: 502 },
    );
  }
}

Bun.serve<{ wsTag: boolean }>({
  port: PORT,
  hostname: "0.0.0.0",
  async fetch(req, srv) {
    const url = new URL(req.url);
    if (url.pathname.startsWith("/ws")) {
      if (srv.upgrade(req, { data: { wsTag: true } })) return;
      return new Response("upgrade failed", { status: 400 });
    }
    if (url.pathname === "/healthz") return new Response("ok");
    if (url.pathname === "/__journal") return wmFetch("/__admin/requests");
    if (url.pathname === "/__mock/state")
      return Response.json({ sockets: sockets.size });
    if (url.pathname.startsWith("/__mock/")) {
      return controlApi(req, url.pathname.slice("/__mock".length));
    }
    const oaHost = url.pathname.split("/")[1] ?? "";
    const oaRest = url.pathname.slice(oaHost.length + 1) || "/";
    const oa = await oaHttp(req, oaHost, oaRest);
    if (oa !== null) return oa;
    return proxy(req, url);
  },
  websocket: {
    open(ws) {
      // Real Zalo keeps one listener per session: a new connection kicks
      // the stale one with cmd 3000. Mirror that so tests and deployments
      // never see one event on two sockets.
      for (const s of sockets) s.close(3000);
      sockets.add(ws);
      console.log(`[mock] ws open sockets=${sockets.size}`);
      // Cipher key frame, cmd 1 sub 1. Events go out with encrypt=0 so the
      // value is never used for decryption.
      ws.send(wsFrame(1, 1, { key: Buffer.alloc(16, 7).toString("base64") }));
    },
    async message(ws, message) {
      const data =
        typeof message === "string"
          ? new TextEncoder().encode(message)
          : new Uint8Array(message);
      if (data.length < 4) return;
      const cmd = data[1] | (data[2] << 8);
      const sub = data[3];
      if (cmd === 2) return; // ping
      let parsed: { data?: Json } = {};
      try {
        parsed = JSON.parse(new TextDecoder().decode(data.subarray(4)));
      } catch {
        return;
      }
      const d = parsed.data ?? {};
      const lastId = typeof d.lastId === "string" ? d.lastId : null;
      const serve = <T extends { ts?: unknown }>(items: T[]): T[] => {
        if (lastId === null) return items;
        const cut = Number(lastId);
        const older = items.filter((i) => Number(i.ts) < cut);
        return older.length > 0 ? older : items;
      };
      if (cmd === 510 || cmd === 511) {
        const items = serve(
          cmd === 510 ? oldStore.userMsgs : oldStore.groupMsgs,
        );
        ws.send(
          wsFrame(cmd, sub, {
            data: JSON.stringify({
              data:
                cmd === 510 ? { msgs: items } : { groupMsgs: items },
            }),
            encrypt: 0,
          }),
        );
        return;
      }
      if (cmd === 610 || cmd === 611) {
        const items =
          cmd === 610 ? oldStore.userReacts : oldStore.groupReacts;
        ws.send(
          wsFrame(cmd, sub, {
            data: JSON.stringify({
              data:
                cmd === 610
                  ? { reacts: items }
                  : { reactGroups: items },
            }),
            encrypt: 0,
          }),
        );
      }
    },
    close(ws, code, reason) {
      sockets.delete(ws);
      console.log(`[mock] ws close code=${code} reason=${reason} sockets=${sockets.size}`);
    },
  },
});

console.log(`zalo-mock gateway on :${PORT}, wiremock at ${WIREMOCK}`);
