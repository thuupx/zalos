// Stateful offline Zalo responses for the Phase D conversation APIs:
// hidden/archived conversations, labels, per-conversation auto-delete and
// linked devices.
//
// These endpoints cannot be plain WireMock stubs: label updates carry a
// version that must advance (and reject stale writes), hidden/archive
// lists mutate, and auto-delete is a per-thread map. The gateway answers
// them from this in-memory state after decrypting `params`, the same way
// it already handles the OA token rotation and QR scenarios. The seed
// values are realistic fixtures so a dev build shows non-empty screens.

export type Json = Record<string, unknown>;

export type PhaseDHiddenThread = {
  is_group: number;
  thread_id: string;
};

export type PhaseDArchivedItem = {
  id: string;
  type: number;
};

export type PhaseDLabel = {
  id: number;
  text: string;
  textKey: string;
  conversations: string[];
  color: string;
  offset: number;
  emoji: string;
  createTime: number;
};

export type PhaseDAutoDelete = {
  destId: string;
  isGroup: boolean;
  ttl: number;
  createdAt: number;
};

export type PhaseDDevices = {
  masterId: string;
  encIdentity: string;
  lastUpdateTs: number;
  encSignature: string;
  companions: Json[];
};

export type PhaseDQuickMessage = {
  id: number;
  keyword: string;
  type: number;
  createdTime: number;
  lastModified: number;
  message: { title: string; params: string | null };
  media: { items: Json[] } | null;
};

export type PhaseDState = {
  hidden: { pin: string; threads: PhaseDHiddenThread[] };
  archived: { items: PhaseDArchivedItem[]; version: number };
  labels: { labelData: PhaseDLabel[]; version: number; lastUpdateTime: number };
  autoDelete: { convers: PhaseDAutoDelete[] };
  devices: { devices: PhaseDDevices };
  quickMessages: {
    items: PhaseDQuickMessage[];
    version: number;
    cursor: number;
  };
};

export type PhaseDResult =
  | { ok: true; data: unknown }
  | { ok: false; code: number; message: string };

const SEED_TS = 1_700_000_000_000;

// Static bank fixtures: the real list is a catalogue, not account state.
export const PHASE_D_BANKS = [
  {
    bin: 970436,
    logo: "http://mock-media.zdn.vn/banks/vietcombank.png",
    name: "Ngân hàng TMCP Ngoại Thương Việt Nam",
    name_eng: "Joint Stock Commercial Bank for Foreign Trade of Vietnam",
    short_name: "Vietcombank",
    search_key_word: "vietcombank vcb",
  },
  {
    bin: 970422,
    logo: "http://mock-media.zdn.vn/banks/mbbank.png",
    name: "Ngân hàng TMCP Quân đội",
    name_eng: "Military Commercial Joint Stock Bank",
    short_name: "MB Bank",
    search_key_word: "mb bank quan doi",
  },
  {
    bin: 970407,
    logo: "http://mock-media.zdn.vn/banks/techcombank.png",
    name: "Ngân hàng TMCP Kỹ thương Việt Nam",
    name_eng: "Vietnam Technological and Commercial Joint Stock Bank",
    short_name: "Techcombank",
    search_key_word: "techcombank tcb",
  },
];

export const PHASE_D_BANK_ACCOUNTS = [
  {
    id: "bank-acc-1",
    bin: 970436,
    default: true,
    bank_number: "0123456789",
    holder_name: "NGUYEN VAN A",
    created_at: SEED_TS,
    updated_at: SEED_TS,
    account_id: 101,
    is_default: true,
    bank_name: "Vietcombank",
    bank_logo: "http://mock-media.zdn.vn/banks/vietcombank.png",
  },
  {
    id: "bank-acc-2",
    bin: 970422,
    default: false,
    bank_number: "9876543210",
    holder_name: "NGUYEN VAN A",
    created_at: SEED_TS,
    updated_at: SEED_TS,
    account_id: 102,
    is_default: false,
    bank_name: "MB Bank",
    bank_logo: "http://mock-media.zdn.vn/banks/mbbank.png",
  },
];

export function createPhaseDState(): PhaseDState {
  return {
    hidden: {
      // A non-empty opaque hash means "a PIN is set"; it is not a
      // plaintext PIN and the server must never return it.
      pin: "9f2c1a7b4e6d8035a1b2c3d4e5f60718",
      threads: [
        { is_group: 0, thread_id: "777000222" },
        { is_group: 1, thread_id: "880000111" },
      ],
    },
    archived: {
      items: [
        { id: "880000111", type: 1 },
        { id: "777000333", type: 0 },
      ],
      version: 7,
    },
    labels: {
      labelData: [
        {
          id: 1,
          text: "Gia đình",
          textKey: "",
          conversations: ["777000222"],
          color: "#e91e63",
          offset: 0,
          emoji: "",
          createTime: SEED_TS,
        },
        {
          id: 2,
          text: "Công việc",
          textKey: "",
          conversations: ["880000111"],
          color: "#2196f3",
          offset: 1,
          emoji: "",
          createTime: SEED_TS,
        },
        {
          id: 3,
          text: "Bạn bè",
          textKey: "",
          conversations: ["777000333", "880000111"],
          color: "#4caf50",
          offset: 2,
          emoji: "",
          createTime: SEED_TS,
        },
      ],
      version: 3,
      lastUpdateTime: SEED_TS,
    },
    autoDelete: {
      convers: [
        {
          destId: "777000222",
          isGroup: false,
          ttl: 86_400_000,
          createdAt: SEED_TS,
        },
        {
          destId: "880000111",
          isGroup: true,
          ttl: 604_800_000,
          createdAt: SEED_TS,
        },
      ],
    },
    devices: {
      devices: {
        masterId: "777000111",
        // Opaque fixture blobs; the real gateway never logs or returns
        // these fields.
        encIdentity: "mock-enc-identity-opaque",
        lastUpdateTs: SEED_TS,
        encSignature: "mock-enc-signature-opaque",
        companions: [
          {
            deviceName: "iPhone 15",
            platform: "ios",
            lastUpdateTs: SEED_TS,
            current: true,
          },
          {
            data: {
              deviceName: "MacBook Pro",
              platform: "macos",
              lastUpdateTs: SEED_TS - 60_000,
            },
          },
          // Unknown shape: the gateway exposes only a value-free summary.
          { opaque: "not-a-device-field" },
        ],
      },
    },
    quickMessages: {
      items: [
        {
          id: 1,
          keyword: "chao",
          type: 0,
          createdTime: SEED_TS,
          lastModified: SEED_TS,
          message: { title: "Chào bạn, mình có thể giúp gì?", params: null },
          media: null,
        },
        {
          id: 2,
          keyword: "banggia",
          type: 1,
          createdTime: SEED_TS,
          lastModified: SEED_TS,
          message: { title: "Bảng giá tháng này", params: null },
          media: {
            items: [
              {
                type: 0,
                photoId: 9001,
                title: "",
                width: 640,
                height: 480,
                previewThumb: "http://mock-media.zdn.vn/qm/thumb.jpg",
                rawUrl: "http://mock-media.zdn.vn/qm/raw.jpg",
                thumbUrl: "http://mock-media.zdn.vn/qm/thumb.jpg",
                normalUrl: "http://mock-media.zdn.vn/qm/normal.jpg",
                hdUrl: "http://mock-media.zdn.vn/qm/hd.jpg",
              },
            ],
          },
        },
      ],
      version: 4,
      cursor: 2,
    },
  };
}

function threadKey(t: { is_group: number; thread_id: string }): string {
  return `${t.is_group}:${t.thread_id}`;
}

function parseHiddenThreads(v: unknown): PhaseDHiddenThread[] {
  let raw = v;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw) as unknown;
    } catch {
      return [];
    }
  }
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((item) => {
    if (item === null || typeof item !== "object") return [];
    const o = item as Json;
    const id = typeof o.thread_id === "string" ? o.thread_id : "";
    if (id === "") return [];
    return [{ is_group: Number(o.is_group) === 1 ? 1 : 0, thread_id: id }];
  });
}

function archivedItemOf(v: unknown): PhaseDArchivedItem[] {
  if (v === null || typeof v !== "object") return [];
  const o = v as Json;
  const id =
    typeof o.id === "string"
      ? o.id
      : typeof o.threadId === "string"
        ? o.threadId
        : "";
  if (id === "") return [];
  const type = Number(o.type ?? o.isGroup) === 1 ? 1 : 0;
  return [{ id, type }];
}

function archivedKey(i: PhaseDArchivedItem): string {
  return `${i.type}:${i.id}`;
}

function parseLabelData(v: unknown): PhaseDLabel[] | null {
  let raw = v;
  if (typeof raw === "string") {
    try {
      raw = JSON.parse(raw) as unknown;
    } catch {
      return null;
    }
  }
  if (!Array.isArray(raw)) return null;
  const out: PhaseDLabel[] = [];
  for (const item of raw) {
    if (item === null || typeof item !== "object") return null;
    const o = item as Json;
    if (
      typeof o.id !== "number" ||
      !Number.isInteger(o.id) ||
      typeof o.text !== "string"
    ) {
      return null;
    }
    out.push({
      id: o.id,
      text: o.text,
      textKey: typeof o.textKey === "string" ? o.textKey : "",
      conversations: Array.isArray(o.conversations)
        ? o.conversations.filter((c): c is string => typeof c === "string")
        : [],
      color: typeof o.color === "string" ? o.color : "",
      offset: Number.isFinite(Number(o.offset)) ? Number(o.offset) : 0,
      emoji: typeof o.emoji === "string" ? o.emoji : "",
      createTime: Number.isFinite(Number(o.createTime))
        ? Number(o.createTime)
        : 0,
    });
  }
  return out;
}

function labelsPayload(state: PhaseDState) {
  return {
    // The wire shape carries labelData as a JSON string; zca-js parses it.
    labelData: JSON.stringify(state.labels.labelData),
    version: state.labels.version,
    lastUpdateTime: state.labels.lastUpdateTime,
  };
}

function parseQuickDraft(p: Json): {
  keyword: string;
  title: string;
  media: { items: Json[] } | null;
} | null {
  const keyword = typeof p.keyword === "string" ? p.keyword.trim() : "";
  const message =
    p.message !== null && typeof p.message === "object" && !Array.isArray(p.message)
      ? (p.message as Json)
      : null;
  const title = typeof message?.title === "string" ? message.title : "";
  if (keyword === "" || title === "") return null;
  const rawMedia =
    p.media !== null && typeof p.media === "object" && !Array.isArray(p.media)
      ? (p.media as Json)
      : null;
  const media =
    rawMedia !== null && Array.isArray(rawMedia.items)
      ? { items: rawMedia.items as Json[] }
      : null;
  return { keyword, title, media };
}

// Handles one Phase D endpoint. Returns null for anything else so the
// caller proxies it to WireMock as before.
export function phaseDResponse(
  state: PhaseDState,
  method: string,
  rest: string,
  params: Json | null,
): PhaseDResult | null {
  const p = params ?? {};
  switch (rest) {
    case "/api/hiddenconvers/get-all":
      if (method !== "GET") return null;
      return {
        ok: true,
        data: { pin: state.hidden.pin, threads: state.hidden.threads },
      };

    case "/api/hiddenconvers/add-remove": {
      if (method !== "POST") return null;
      const add = parseHiddenThreads(p.add_threads);
      const del = parseHiddenThreads(p.del_threads);
      const remove = new Set(del.map(threadKey));
      state.hidden.threads = state.hidden.threads.filter(
        (t) => !remove.has(threadKey(t)),
      );
      for (const t of add) {
        if (!state.hidden.threads.some((x) => threadKey(x) === threadKey(t))) {
          state.hidden.threads.push(t);
        }
      }
      return { ok: true, data: "" };
    }

    case "/api/hiddenconvers/update-pin":
      if (method !== "GET") return null;
      if (typeof p.new_pin === "string" && p.new_pin !== "") {
        // zca-js already hashed the PIN before sending it.
        state.hidden.pin = p.new_pin;
      }
      return { ok: true, data: "" };

    case "/api/hiddenconvers/reset":
      if (method !== "GET") return null;
      state.hidden.pin = "";
      return { ok: true, data: "" };

    case "/api/archivedchat/list":
      if (method !== "GET") return null;
      return {
        ok: true,
        data: {
          items: state.archived.items,
          version: state.archived.version,
        },
      };

    case "/api/archivedchat/update": {
      if (method !== "POST") return null;
      const ids = Array.isArray(p.ids) ? p.ids.flatMap(archivedItemOf) : [];
      const keys = new Set(ids.map(archivedKey));
      const action = Number(p.actionType);
      state.archived.items = state.archived.items.filter(
        (i) => !keys.has(archivedKey(i)),
      );
      // actionType 0 archives, 1 unarchives (zca-js mapping).
      if (action === 0) {
        for (const item of ids) {
          if (
            !state.archived.items.some(
              (i) => archivedKey(i) === archivedKey(item),
            )
          ) {
            state.archived.items.push(item);
          }
        }
      }
      const clientVersion = Number(p.version);
      state.archived.version =
        Math.max(
          state.archived.version,
          Number.isFinite(clientVersion) ? clientVersion : 0,
        ) + 1;
      return {
        ok: true,
        data: {
          needSync: false,
          // zca-js types the field as needResync; real responses use
          // needSync. Send both so either reader converges.
          needResync: false,
          version: state.archived.version,
        },
      };
    }

    case "/api/convlabel/get":
      if (method !== "GET") return null;
      return { ok: true, data: labelsPayload(state) };

    case "/api/convlabel/update": {
      if (method !== "POST") return null;
      const version = Number(p.version);
      if (version !== state.labels.version) {
        return { ok: false, code: 1005, message: "label version mismatch" };
      }
      const parsed = parseLabelData(p.labelData);
      if (parsed === null) {
        return { ok: false, code: 1002, message: "invalid label data" };
      }
      state.labels.labelData = parsed;
      state.labels.version = version + 1;
      state.labels.lastUpdateTime = Date.now();
      return { ok: true, data: labelsPayload(state) };
    }

    case "/api/conv/autodelete/getConvers":
      if (method !== "GET") return null;
      return { ok: true, data: { convers: state.autoDelete.convers } };

    case "/api/conv/autodelete/updateConvers": {
      if (method !== "POST") return null;
      const threadId =
        typeof p.threadId === "string" ? p.threadId : String(p.threadId ?? "");
      if (threadId === "") {
        return { ok: false, code: 1002, message: "threadId required" };
      }
      const isGroup =
        p.isGroup === 1 || p.isGroup === true || p.isGroup === "1";
      const ttl = Number(p.ttl);
      state.autoDelete.convers = state.autoDelete.convers.filter(
        (c) => !(c.destId === threadId && c.isGroup === isGroup),
      );
      if (Number.isFinite(ttl) && ttl > 0) {
        state.autoDelete.convers.push({
          destId: threadId,
          isGroup,
          ttl,
          createdAt: Date.now(),
        });
      }
      return { ok: true, data: "" };
    }

    case "/api/devices/linked":
      if (method !== "GET") return null;
      return { ok: true, data: { devices: state.devices.devices } };

    case "/api/transfer/conf":
      if (method !== "GET") return null;
      return { ok: true, data: { banks: PHASE_D_BANKS } };

    case "/api/transfer/list": {
      if (method !== "GET") return null;
      const page = Number(p.page ?? 0);
      const limit = Number(p.limit ?? 20);
      const start = Number.isFinite(page) && page > 0 ? page * limit : 0;
      const size = Number.isFinite(limit) && limit > 0 ? limit : 20;
      const rows = PHASE_D_BANK_ACCOUNTS.slice(start, start + size);
      return {
        ok: true,
        data: {
          hasMore: start + rows.length < PHASE_D_BANK_ACCOUNTS.length,
          total: PHASE_D_BANK_ACCOUNTS.length,
          myBanks: rows,
        },
      };
    }

    case "/api/message/parselink": {
      if (method !== "GET") return null;
      const link = typeof p.link === "string" ? p.link : "";
      return {
        ok: true,
        data: {
          data: {
            thumb: "http://mock-media.zdn.vn/link/thumb.jpg",
            title: "Mock link preview",
            desc: "A preview served by the offline Zalo mock",
            src: "mock-media.zdn.vn",
            href: link,
            media: {
              type: 0,
              count: 0,
              mediaTitle: "",
              artist: "",
              streamUrl: "",
              stream_icon: "",
            },
            stream_icon: "",
          },
          error_maps: {},
        },
      };
    }

    case "/api/quickmessage/list":
      if (method !== "GET") return null;
      return {
        ok: true,
        data: {
          cursor: state.quickMessages.cursor,
          version: state.quickMessages.version,
          items: state.quickMessages.items,
        },
      };

    case "/api/quickmessage/create": {
      if (method !== "GET") return null;
      const draft = parseQuickDraft(p);
      if (draft === null) {
        return { ok: false, code: 1002, message: "invalid quick message" };
      }
      const now = Date.now();
      const id =
        Math.max(0, ...state.quickMessages.items.map((i) => i.id)) + 1;
      const item: PhaseDQuickMessage = {
        id,
        keyword: draft.keyword,
        type: draft.media !== null ? 1 : 0,
        createdTime: now,
        lastModified: now,
        message: { title: draft.title, params: "" },
        media: draft.media,
      };
      state.quickMessages.items.push(item);
      state.quickMessages.version++;
      state.quickMessages.cursor++;
      return {
        ok: true,
        data: { item, version: state.quickMessages.version },
      };
    }

    case "/api/quickmessage/update": {
      if (method !== "GET") return null;
      const id = Number(p.itemId);
      const item = state.quickMessages.items.find((i) => i.id === id);
      if (item === undefined) {
        // zca-js documents 212 for a missing quick message.
        return { ok: false, code: 212, message: "quick message not found" };
      }
      const draft = parseQuickDraft(p);
      if (draft === null) {
        return { ok: false, code: 1002, message: "invalid quick message" };
      }
      item.keyword = draft.keyword;
      item.message = { title: draft.title, params: "" };
      if (draft.media !== null) {
        item.media = draft.media;
        item.type = 1;
      }
      item.lastModified = Date.now();
      state.quickMessages.version++;
      state.quickMessages.cursor++;
      return {
        ok: true,
        data: { item, version: state.quickMessages.version },
      };
    }

    case "/api/quickmessage/delete": {
      if (method !== "GET") return null;
      const ids = Array.isArray(p.itemIds)
        ? p.itemIds
            .map((v) => Number(v))
            .filter((v) => Number.isFinite(v) && v > 0)
        : [];
      const remove = new Set(ids);
      state.quickMessages.items = state.quickMessages.items.filter(
        (i) => !remove.has(i.id),
      );
      state.quickMessages.version++;
      state.quickMessages.cursor++;
      return {
        ok: true,
        data: { itemIds: ids, version: state.quickMessages.version },
      };
    }

    default:
      return null;
  }
}

// Control-API view: no PIN hash, no device identity/signature blobs.
export function phaseDStateSnapshot(state: PhaseDState) {
  return {
    hidden: {
      pinSet: state.hidden.pin !== "",
      threads: state.hidden.threads,
    },
    archived: state.archived,
    labels: {
      labels: state.labels.labelData,
      version: state.labels.version,
      lastUpdateTime: state.labels.lastUpdateTime,
    },
    autoDelete: state.autoDelete,
    devices: {
      masterId: state.devices.devices.masterId,
      lastUpdateTs: state.devices.devices.lastUpdateTs,
      companionCount: state.devices.devices.companions.length,
    },
    quickMessages: {
      count: state.quickMessages.items.length,
      version: state.quickMessages.version,
      cursor: state.quickMessages.cursor,
    },
  };
}
