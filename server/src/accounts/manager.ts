// Owns one ZaloGateway per account slot: persists every gateway event into
// messages/threads/events and broadcasts sequenced events to all connected
// account channels of that slot.
import type { Store } from "../store/db.ts";
import { AUTO_DELETE_TTLS } from "../gateway/types.ts";
import { CallManager } from "./call_manager.ts";
import type {
  ArchivedChatList,
  AutoDeleteChat,
  BankAccount,
  BankAccounts,
  BankInfo,
  ContactCard,
  ConversationRef,
  Credentials,
  GatewayFactory,
  GatewaySelf,
  HiddenConversations,
  Label,
  LabelsState,
  LinkPreview,
  LinkedDevices,
  Message,
  OaCredentials,
  OaHooks,
  QuickMessage,
  QuickMessageDraft,
  QuickMessages,
  StyleRun,
  ThreadType,
  Urgency,
  UserInfo,
  ZaloGateway,
} from "../gateway/types.ts";
import { RpcError } from "../tunnel/rpc.ts";
import type { TunnelServer } from "../tunnel/server.ts";
import { msgAad, sealRecord, sha256Hex } from "../vault.ts";
import {
  clearAccountMedia,
  deleteMediaObjects,
  enableAccountMedia,
  sealMediaCache,
  withMediaCacheLock,
} from "../media.ts";

function messageMediaHashes(message: Message): string[] {
  const urls = new Set<string>();
  const add = (u: string | undefined) => {
    if (typeof u === "string" && /^https?:\/\//i.test(u)) urls.add(u);
  };
  for (const att of message.attachments ?? []) {
    add(att.url);
    add(att.thumbUrl);
  }
  add(message.sticker?.url);
  add(message.doodle?.url);
  for (const item of message.album?.items ?? []) {
    add(item.url);
    add(item.thumbUrl);
  }
  return [...urls].map((u) => sha256Hex(u));
}

export class AccountManager {
  private gateways = new Map<string, ZaloGateway>();
  // Per-slot expiry sweeper. Two kinds of expiry exist and never share a
  // rule: per-conversation auto-delete (thread TTL) and per-message
  // self-destruct (message TTL). A sweep is shared while it runs so two
  // timer ticks can never overlap; timers are cleared with the slot.
  private sweepTimers = new Map<string, ReturnType<typeof setInterval>>();
  private ttlTimers = new Map<string, ReturnType<typeof setInterval>>();
  // One chain per slot serializes both sweep kinds, so a row deleted by
  // one sweep can never also be reported deleted by the other.
  private sweepChains = new Map<string, Promise<unknown>>();
  private readonly sweepMs: number;
  private readonly ttlSweepMs: number;
  // Whole-set label updates are read-modify-write; one queue per account
  // serializes them so a stale version cannot slip through.
  private labelTails = new Map<string, Promise<unknown>>();
  // One in-flight send per slot+cliId, keyed with the canonical request hash
  // so reusing a cliId for a different method/target/body returns conflict.
  private inflightSends = new Map<
    string,
    { hash: string; promise: Promise<{ msgId: string; cliId: string }> }
  >();
  readonly calls: CallManager;

  constructor(
    private store: Store,
    private factory: GatewayFactory,
    private tunnel: TunnelServer,
    opts: { autoDeleteSweepMs?: number; messageTtlSweepMs?: number } = {},
  ) {
    this.sweepMs = opts.autoDeleteSweepMs ?? 60_000;
    // Tests that disable the auto-delete timer disable both by default.
    this.ttlSweepMs =
      opts.messageTtlSweepMs ?? opts.autoDeleteSweepMs ?? 60_000;
    this.calls = new CallManager((slot) => this.gateway(slot), tunnel, store);
    tunnel.onManifestChanged(() => {});
    // No media requests or gateways exist yet in this process. Finish any
    // interrupted vault publication before the server can accept new writes.
    this.resumeVaultMigrations();
  }

  gateway(slot: string): ZaloGateway {
    const gw = this.gateways.get(slot);
    if (gw === undefined) throw new RpcError("account_offline", slot);
    return gw;
  }

  vaultKey(slot: string): Uint8Array | null {
    const a = this.store.accountBySlot(slot);
    if (a === null || a.vault_public_key === null) return null;
    return new Uint8Array(Buffer.from(a.vault_public_key, "base64"));
  }

  vaultKeyInfo(slot: string): { key: Uint8Array; version: number } | null {
    const a = this.store.accountBySlot(slot);
    if (a === null || a.vault_public_key === null) return null;
    return {
      key: new Uint8Array(Buffer.from(a.vault_public_key, "base64")),
      version: a.vault_key_version ?? 1,
    };
  }

  async rotateVaultKey(
    slot: string,
    expectedVersion: number,
    encodedPublicKey: string,
  ): Promise<number> {
    return await withMediaCacheLock(this.store.dir, slot, () => {
      const account = this.store.accountBySlot(slot);
      if (account === null) throw new RpcError("not_found", slot);
      if (account.vault_public_key === null) {
        throw new RpcError("bad_request", "vault key not initialized");
      }
      const nextVersion = this.store.rotateVaultKey(
        slot,
        expectedVersion,
        encodedPublicKey,
      );
      if (nextVersion === null) {
        throw new RpcError("conflict", "vault key version mismatch");
      }
      return nextVersion;
    });
  }

  // The stored record is identical to the wire record: clear fields plus
  // either `sealed` (when the account has a vault key) or `body`.
  private recordFor(slot: string, m: Message) {
    const base = {
      id: m.id,
      cliId: m.cliId,
      threadId: m.threadId,
      threadType: m.threadType,
      senderId: m.senderId,
      ts: m.ts,
      isSelf: m.isSelf,
      kind: m.kind,
      reactions: m.reactions,
      recalled: m.recalled,
    };
    const body: Record<string, unknown> = { senderName: m.senderName };
    if (m.text !== undefined) body.text = m.text;
    if (m.attachments !== undefined) body.attachments = m.attachments;
    if (m.sticker !== undefined) body.sticker = m.sticker;
    if (m.card !== undefined) body.card = m.card;
    if (m.bankCard !== undefined) body.bankCard = m.bankCard;
    if (m.location !== undefined) body.location = m.location;
    if (m.poll !== undefined) body.poll = m.poll;
    if (m.note !== undefined) body.note = m.note;
    if (m.reminder !== undefined) body.reminder = m.reminder;
    if (m.callLog !== undefined) body.callLog = m.callLog;
    if (m.doodle !== undefined) body.doodle = m.doodle;
    if (m.album !== undefined) body.album = m.album;
    if (m.todo !== undefined) body.todo = m.todo;
    if (m.styles !== undefined) body.styles = m.styles;
    if (m.urgency !== undefined) body.urgency = m.urgency;
    if (m.ttl !== undefined) body.ttl = m.ttl;
    if (m.expiresAt !== undefined) body.expiresAt = m.expiresAt;
    if (m.quote !== undefined) body.quote = m.quote;
    if (m.mentions !== undefined) body.mentions = m.mentions;
    if (m.raw !== undefined) body.raw = m.raw;
    const info = this.vaultKeyInfo(slot);
    if (info !== null) {
      return {
        ...base,
        kv: info.version,
        sealed: sealRecord(info.key, msgAad(slot, m.id), JSON.stringify(body)),
      };
    }
    return { ...base, body };
  }

  // One SQLite transaction for persist + thread update + event append.
  private tx(fn: () => void) {
    this.store.db.transaction(fn)();
  }

  private emit(slot: string, type: string, data: unknown) {
    const row = this.store.appendEvent(slot, type, data);
    this.tunnel.broadcastAccount(slot, type, data, row.seq);
    return row.seq;
  }

  private emitMessage(slot: string, type: string, record: unknown) {
    const row = this.store.appendEvent(slot, type, { message: record });
    this.tunnel.broadcastAccount(slot, type, { message: record }, row.seq);
  }

  private threadUpdated(slot: string, threadId: string, threadType: ThreadType) {
    const thread = this.threadWithLast(slot, threadId, threadType);
    if (thread !== null) {
      this.emit(slot, "thread.updated", { thread });
    }
  }

  threadWithLast(slot: string, threadId: string, threadType: ThreadType) {
    const row = this.store.getThread(slot, threadId, threadType);
    if (row === null) return null;
    const last =
      row.last_msg_id !== null && row.last_msg_id !== undefined
        ? this.store.getMessage(slot, row.last_msg_id as string)
        : null;
    return {
      id: row.thread_id,
      type: row.type,
      name: row.name,
      avatarUrl: row.avatar_url,
      lastMessage: last === null ? null : rowToRecord(last),
      lastTs: row.last_ts,
      unread: row.unread,
      pinned: !!row.pinned,
      muted: !!row.muted,
      hidden: !!row.hidden,
      archived: !!row.archived,
      autoDeleteTtl: Number(row.auto_delete_ttl ?? 0),
    };
  }

  private duplicate(slot: string, message: Message): boolean {
    if (message.cliId !== null && message.cliId !== "") {
      if (this.store.getMessageByCliId(slot, message.cliId) !== null) {
        return true;
      }
    }
    return this.store.getMessage(slot, message.id) !== null;
  }

  // Fills a still-empty user thread name from the profiles cache inside
  // the caller's transaction, so the first thread.updated of a thread
  // whose peer is already known goes out named. Uncached names are
  // resolved by ensureThreadName and arrive in a later thread.updated.
  private cachedThreadName(slot: string, threadId: string, type: ThreadType) {
    if (type !== "user") return;
    const row = this.store.getThread(slot, threadId, type);
    if (row === null || row.name !== "") return;
    const cached = this.store.getProfileFresh(
      slot,
      threadId,
      "user",
      24 * 3600 * 1000,
    );
    if (cached !== null && cached.name !== "") {
      this.store.updateThreadProfile(
        slot,
        threadId,
        type,
        cached.name,
        cached.avatar_url,
      );
    }
  }

  // Message payloads never carry the peer's name; threads start with an
  // empty name. Resolve it once per thread (profiles cache for users,
  // getGroupInfo for groups), persist it, and push thread.updated so all
  // devices see the real name. A cached empty profile is not re-fetched.
  private threadNameInflight = new Set<string>();
  // One background member refresh per slot+group. Membership and setting
  // events only invalidate; the refetch itself never blocks the listener.
  private groupMemberRefreshes = new Set<string>();

  private ensureThreadName(
    slot: string,
    threadId: string,
    type: ThreadType,
  ) {
    const row = this.store.getThread(slot, threadId, type);
    if (row === null || row.name !== "") return;
    const key = `${slot}:${type}:${threadId}`;
    if (this.threadNameInflight.has(key)) return;
    if (type === "user") {
      const cached = this.store.getProfileFresh(
        slot,
        threadId,
        "user",
        24 * 3600 * 1000,
      );
      // A cached lookup (even an empty one) is authoritative for 24 h;
      // apply it to the thread row instead of hitting Zalo again.
      if (cached !== null) {
        if (cached.name !== "") {
          this.store.updateThreadProfile(
            slot,
            threadId,
            type,
            cached.name,
            cached.avatar_url,
          );
          this.threadUpdated(slot, threadId, type);
        }
        return;
      }
    }
    this.threadNameInflight.add(key);
    void (async () => {
      try {
        const gw = this.gateways.get(slot);
        if (gw === undefined) return;
        let name = "";
        let avatarUrl = "";
        if (type === "group") {
          const info = await gw.groupInfo(threadId);
          name = info.name;
          avatarUrl = info.avatarUrl ?? "";
        } else {
          // Zalo may answer with more profiles than asked for; pick ours.
          const info = (await gw.userInfo([threadId])).find(
            (u) => u.uid === threadId,
          );
          if (info !== undefined) {
            this.store.upsertProfile({
              slot,
              uid: threadId,
              kind: "user",
              name: info.displayName,
              avatarUrl: info.avatarUrl,
              fetchedAt: Date.now(),
            });
            name = info.displayName;
            avatarUrl = info.avatarUrl;
          }
        }
        if (name !== "") {
          this.store.updateThreadProfile(slot, threadId, type, name, avatarUrl);
          this.threadUpdated(slot, threadId, type);
        }
      } catch {
        // Offline or unresolvable; the next message or sync retries.
      } finally {
        this.threadNameInflight.delete(key);
      }
    })();
  }

  // Zalo replays the same old messages on every listener start and the
  // group history endpoint overlaps what is stored: a stored message is
  // skipped, so it is never re-counted as unread and its folded state
  // (reactions, delivery, recall) is never overwritten by the bare replay.
  // On-demand pages of old history (`unread: false`) never count as unread.
  // Returns whether the message was new.
  private ingestHistory(
    slot: string,
    message: Message,
    opts: { unread: boolean } = { unread: true },
  ): boolean {
    if (this.duplicate(slot, message)) return false;
    this.tx(() => {
      this.store.upsertThread({
        slot,
        threadId: message.threadId,
        type: message.threadType,
      });
      this.store.upsertMessage({
        ...messageToRow(slot, message),
        bodyJson: JSON.stringify(this.recordFor(slot, message)),
      });
      this.store.recordMediaRefs(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        messageMediaHashes(message),
      );
      // History can be older than what is stored; the thread keeps its
      // newest message as last.
      const thread = this.store.getThread(
        slot,
        message.threadId,
        message.threadType,
      );
      if (thread === null || Number(thread.last_ts) <= message.ts) {
        this.store.updateThreadLast(
          slot,
          message.threadId,
          message.threadType,
          message.id,
          message.ts,
        );
      }
      if (opts.unread && !message.isSelf) {
        this.store.bumpUnread(slot, message.threadId, message.threadType, 1);
      }
      this.cachedThreadName(slot, message.threadId, message.threadType);
    });
    this.ensureThreadName(slot, message.threadId, message.threadType);
    return true;
  }

  private persistIncoming(slot: string, message: Message) {
    this.tx(() => {
      this.store.upsertThread({
        slot,
        threadId: message.threadId,
        type: message.threadType,
      });
      this.store.upsertMessage({
        ...messageToRow(slot, message),
        bodyJson: JSON.stringify(this.recordFor(slot, message)),
      });
      this.store.recordMediaRefs(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        messageMediaHashes(message),
      );
      this.store.updateThreadLast(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        message.ts,
      );
      if (!message.isSelf) {
        this.store.bumpUnread(slot, message.threadId, message.threadType, 1);
        this.tunnel.notifyManifestChanged();
      }
      this.cachedThreadName(slot, message.threadId, message.threadType);
      this.emitMessage(slot, "message.new", this.recordFor(slot, message));
      this.threadUpdated(slot, message.threadId, message.threadType);
    });
    this.ensureThreadName(slot, message.threadId, message.threadType);
  }

  // Seal every still-plaintext record of this slot (messages and event
  // payloads containing messages), then vacuum so the plaintext is gone
  // from the database file.
  sealExistingRows(
    slot: string,
    publicKey: Uint8Array,
    encodedPublicKey?: string,
  ) {
    const sealBody = (slotId: string, msgId: string, body: unknown) =>
      sealRecord(publicKey, msgAad(slotId, msgId), JSON.stringify(body));
    const tx = this.store.db.transaction(() => {
      for (const row of this.store.allMessageRows(slot)) {
        const rec = JSON.parse(row.body_json) as {
          body?: unknown;
          sealed?: string;
        };
        if (rec.sealed !== undefined || rec.body === undefined) continue;
        const sealed = { ...rec, body: undefined, sealed: sealBody(slot, row.msg_id, rec.body) };
        this.store.updateMessageBody(slot, row.msg_id, JSON.stringify(sealed));
      }
      // Any nested object that looks like a message record (id + body,
      // e.g. message.new and thread.lastMessage inside thread.updated) is
      // re-sealed in place.
      const sealNested = (v: unknown): boolean => {
        let changed = false;
        if (v === null || typeof v !== "object") return false;
        if (Array.isArray(v)) {
          for (const item of v) changed = sealNested(item) || changed;
          return changed;
        }
        const o = v as Record<string, unknown>;
        if (
          typeof o.id === "string" &&
          o.body !== undefined &&
          o.sealed === undefined
        ) {
          o.sealed = sealBody(slot, o.id, o.body);
          delete o.body;
          changed = true;
        }
        for (const item of Object.values(o)) {
          changed = sealNested(item) || changed;
        }
        return changed;
      };
      for (const ev of this.store.allEventRows(slot)) {
        const data = JSON.parse(ev.data_json) as unknown;
        if (sealNested(data)) {
          this.store.updateEventData(slot, ev.seq, JSON.stringify(data));
        }
      }
      // Key installation and every database conversion commit or roll back
      // together. Media ciphertext was already staged before this transaction.
      if (encodedPublicKey !== undefined) {
        this.store.setVaultKey(slot, encodedPublicKey, "migrating");
      } else {
        this.store.setVaultState(slot, "migrating");
      }
    });
    tx();
    this.store.reclaimDeletedData();
  }

  async setVaultKey(
    slot: string,
    encodedPublicKey: string,
    publicKey: Uint8Array,
  ) {
    await withMediaCacheLock(this.store.dir, slot, () => {
      const account = this.store.accountBySlot(slot);
      if (account === null) throw new RpcError("not_found", slot);
      if (
        account.vault_public_key !== null &&
        account.vault_public_key !== encodedPublicKey
      ) {
        throw new RpcError("conflict", "vault key already set");
      }
      // A same-key call deliberately repeats both phases to resume an
      // interrupted filesystem publication instead of reporting a false no-op.
      sealMediaCache(this.store.dir, slot, publicKey, () => {
        this.sealExistingRows(slot, publicKey, encodedPublicKey);
      });
      this.store.setVaultState(slot, "sealed");
    });
  }

  private resumeVaultMigrations() {
    for (const account of this.store.listAccounts()) {
      enableAccountMedia(this.store.dir, account.slot);
      if (account.vault_public_key === null) continue;
      const publicKey = new Uint8Array(
        Buffer.from(account.vault_public_key, "base64"),
      );
      sealMediaCache(this.store.dir, account.slot, publicKey, () => {
        this.sealExistingRows(account.slot, publicKey);
      });
      this.store.setVaultState(account.slot, "sealed");
    }
  }

  private wire(slot: string, gw: ZaloGateway) {
    gw.on("message", (message) => {
      // selfListen echoes our own sends back; the local persist already ran.
      // For media the echo carries real attachment urls the optimistic
      // record did not have: merge and emit message.updated.
      if (this.duplicate(slot, message)) {
        if (
          message.isSelf &&
          (message.attachments !== undefined ||
            (message.sticker !== undefined &&
              message.sticker.url !== undefined) ||
            message.card !== undefined)
        ) {
          this.mergeEcho(slot, message);
        }
        return;
      }
      this.persistIncoming(slot, message);
    });
    gw.on("history", (messages) => {
      // Bulk history ingest: persist but emit a single threads.reset hint
      // instead of one sequenced event per message.
      let added = 0;
      for (const m of messages) if (this.ingestHistory(slot, m)) added++;
      if (added === 0) return;
      this.emit(slot, "threads.reset", {});
      this.tunnel.notifyManifestChanged();
    });
    gw.on("typing", (t) => {
      const profile = this.store.getProfile(slot, t.userId, "user");
      this.tunnel.broadcastAccount(slot, "typing", {
        ...t,
        displayName: profile?.name ?? "",
      });
    });
    gw.on("receipt", (t) => {
      this.emit(slot, "receipt", {
        threadId: t.threadId,
        kind: t.kind,
        userIds: t.userIds,
        msgId: t.msgId,
      });
      this.foldReceipt(slot, t);
    });
    gw.on("friendEvent", (e) => {
      this.contactsChanged(slot);
      const o =
        e !== null && typeof e === "object"
          ? (e as Record<string, unknown>)
          : null;
      const evType = String(o?.type ?? "").toUpperCase();
      if (evType.includes("PIN")) {
        const data =
          o?.data !== null && typeof o?.data === "object"
            ? (o.data as Record<string, unknown>)
            : null;
        const threadId = String(
          o?.threadId ?? data?.conversationId ?? data?.fromUid ?? "",
        );
        if (threadId !== "") {
          this.tunnel.broadcastAccount(slot, "board.updated", {
            threadId,
            threadType: "user",
          });
        }
      }
    });
    gw.on("groupEvent", (e) => {
      this.groupEvent(slot, e);
      const o =
        e !== null && typeof e === "object"
          ? (e as Record<string, unknown>)
          : null;
      const evType = String(o?.type ?? "").toLowerCase();
      if (
        evType.includes("pin") ||
        evType.includes("topic") ||
        evType.includes("note") ||
        evType.includes("remind") ||
        evType.includes("poll")
      ) {
        const data =
          o?.data !== null && typeof o?.data === "object"
            ? (o.data as Record<string, unknown>)
            : null;
        const threadId = String(o?.threadId ?? o?.groupId ?? data?.groupId ?? "");
        if (threadId !== "") {
          this.tunnel.broadcastAccount(slot, "board.updated", {
            threadId,
            threadType: "group",
          });
        }
      }
      this.tunnel.notifyManifestChanged();
    });
    gw.on("reaction", (t) => {
      const row = this.store.getMessage(slot, t.msgId);
      if (row === null) return;
      const rec = rowToRecord(row);
      const changed = applyReaction(rec, t.icon, t.userId);
      // Our own reaction was already persisted optimistically by react().
      if (!changed) return;
      this.tx(() => {
        this.store.updateMessageBody(slot, t.msgId, JSON.stringify(rec));
        this.emitMessage(slot, "message.updated", rec);
      });
    });
    gw.on("recall", (t) => {
      this.store.markRecalled(slot, t.msgId);
      const row = this.store.getMessage(slot, t.msgId);
      if (row === null) return;
      let orphanHashes: string[] = [];
      this.tx(() => {
        const rec = rowToRecord(row);
        // The recalled record keeps only the clear fields.
        for (const k of ["body", "sealed"] as const) delete rec[k];
        rec.recalled = true;
        this.store.updateMessageBody(slot, t.msgId, JSON.stringify(rec));
        // Earlier event entries of this message lose their content too;
        // the entries stay so seq has no gaps.
        this.store.scrubMessageEvents(slot, t.msgId);
        orphanHashes = this.store.releaseMediaRefsForMessages(slot, [t.msgId]);
        this.emitMessage(slot, "message.updated", rec);
      });
      if (orphanHashes.length > 0) {
        void deleteMediaObjects(this.store.dir, slot, orphanHashes).catch(
          () => {},
        );
      }
      this.store.checkpoint();
    });
    gw.on("status", (status) => {
      this.tx(() => {
        this.store.updateAccountStatus(slot, status);
        this.emit(slot, "account.status", { status });
      });
      this.tunnel.notifyManifestChanged();
      if (status === "online") {
        this.startKeepAlive(slot);
        void this.syncConversationState(slot);
      }
    });
    gw.on("credentials", (creds) => {
      // Rotated session cookies: stored in one transaction so a restart
      // logs in with the newest jar instead of the one from QR login.
      this.tx(() => {
        this.store.updateAccountCredentials(slot, JSON.stringify(creds));
      });
    });
    gw.on("self", (s) => {
      this.tx(() => {
        this.store.updateAccountIdentity(
          slot,
          s.uid,
          s.displayName,
          s.avatarUrl,
        );
      });
      this.tunnel.notifyManifestChanged();
    });
    gw.on("voip", (evt) => {
      this.calls.onVoipEvent(slot, evt);
    });
  }

  async addAccount(opts: {
    credentials: Credentials;
    self: GatewaySelf;
  }): Promise<{ slot: string }> {
    const uid = opts.self.uid;
    const known =
      uid === ""
        ? undefined
        : this.store
            .listAccounts()
            .find((a) => a.kind !== "oa" && a.zalo_uid === uid);
    if (known !== undefined) return this.reloginAccount(known.slot, opts);
    const account = this.store.createAccount({
      zaloUid: opts.self.uid,
      displayName: opts.self.displayName,
      avatarUrl: opts.self.avatarUrl,
      credentialsJson: JSON.stringify(opts.credentials),
    });
    enableAccountMedia(this.store.dir, account.slot);
    const gw = this.factory.fromCredentials(opts.credentials, opts.self);
    this.gateways.set(account.slot, gw);
    this.wire(account.slot, gw);
    this.startAutoDeleteSweeper(account.slot);
    this.startTtlSweeper(account.slot);
    this.tunnel.notifyManifestChanged();
    await gw.start();
    return { slot: account.slot };
  }

  // A QR login of a Zalo account that already has a slot renews that
  // slot's session. A second slot would run a second listener for the
  // same Zalo account: Zalo keeps one web listener per account and kicks
  // the other (close 3000), so the two slots displace each other forever
  // and, while both are connected, every message lands in both.
  private async reloginAccount(
    slot: string,
    opts: { credentials: Credentials; self: GatewaySelf },
  ): Promise<{ slot: string }> {
    this.calls.clearSlot(slot);
    enableAccountMedia(this.store.dir, slot);
    const prev = this.gateways.get(slot);
    this.gateways.delete(slot);
    if (prev !== undefined) {
      try {
        await prev.stop();
      } catch {}
    }
    this.tx(() => {
      this.store.updateAccountCredentials(
        slot,
        JSON.stringify(opts.credentials),
      );
      this.store.updateAccountIdentity(
        slot,
        opts.self.uid,
        opts.self.displayName,
        opts.self.avatarUrl,
      );
    });
    const gw = this.factory.fromCredentials(opts.credentials, opts.self);
    this.gateways.set(slot, gw);
    this.wire(slot, gw);
    this.startAutoDeleteSweeper(slot);
    this.startTtlSweeper(slot);
    this.tunnel.notifyManifestChanged();
    await gw.start();
    return { slot };
  }

  async removeAccount(slot: string) {
    this.calls.clearSlot(slot);
    this.stopAutoDeleteSweeper(slot);
    this.stopTtlSweeper(slot);
    // A sweep queued before the timers stopped must finish before its rows
    // disappear, or it would append events for a slot that no longer exists.
    await this.awaitSweeps(slot);
    const gw = this.gateways.get(slot);
    this.gateways.delete(slot);
    if (gw !== undefined) {
      try {
        await gw.stop();
      } catch {}
    }
    await clearAccountMedia(this.store.dir, slot, { retire: true });
    this.store.removeAccount(slot);
    this.tunnel.notifyManifestChanged();
  }

  // Hooks shared by every OA gateway: rotated token pairs are persisted
  // synchronously (single-use refresh tokens must never be lost), and the
  // poll interval follows whether a client watches the slot.
  private oaHooks(slot: () => string): OaHooks {
    return {
      onCredentials: (creds) => {
        const s = slot();
        if (s !== "") {
          this.store.updateAccountCredentials(s, JSON.stringify(creds));
        }
      },
      clientConnected: () => {
        const s = slot();
        return s !== "" && this.tunnel.accountChannels(s).length > 0;
      },
    };
  }

  async addOaAccount(opts: OaCredentials): Promise<{ slot: string }> {
    const fromOa = this.factory.fromOaCredentials;
    if (fromOa === undefined) {
      throw new RpcError("not_supported", "OA gateway unavailable");
    }
    const creds: OaCredentials = {
      appId: opts.appId,
      appSecret: opts.appSecret,
      accessToken: opts.accessToken,
      refreshToken: opts.refreshToken,
      accessTokenExpiresAt: opts.accessTokenExpiresAt,
      oaId: opts.oaId,
    };
    let slot = "";
    const self: GatewaySelf = { uid: "", displayName: "", avatarUrl: "" };
    const gw = fromOa.call(this.factory, creds, self, this.oaHooks(() => slot));
    // Validates the credentials by calling the OA profile endpoint;
    // on success the gateway self is filled and polling has started.
    await gw.start();
    if (self.uid === "" || gw.status === "needs_login") {
      await gw.stop();
      throw new RpcError("auth", "OA credentials rejected");
    }
    const account = this.store.createAccount({
      kind: "oa",
      zaloUid: self.uid,
      displayName: self.displayName,
      avatarUrl: self.avatarUrl,
      // A token refresh can run during validation; store the live pair.
      credentialsJson: JSON.stringify(gw.oaCredentials?.() ?? creds),
    });
    slot = account.slot;
    enableAccountMedia(this.store.dir, account.slot);
    this.gateways.set(account.slot, gw);
    this.wire(account.slot, gw);
    this.startAutoDeleteSweeper(account.slot);
    this.startTtlSweeper(account.slot);
    this.tunnel.notifyManifestChanged();
    return { slot: account.slot };
  }

  async updateOaTokens(
    slot: string,
    accessToken: string,
    refreshToken: string,
  ): Promise<void> {
    const row = this.store.accountBySlot(slot);
    if (row === null || row.kind !== "oa") {
      throw new RpcError("not_found", `OA account ${slot}`);
    }
    const creds = JSON.parse(row.credentials_json) as OaCredentials;
    creds.accessToken = accessToken;
    creds.refreshToken = refreshToken;
    creds.accessTokenExpiresAt = Date.now() + 25 * 3600 * 1000;
    this.store.updateAccountCredentials(slot, JSON.stringify(creds));
    const gw = this.gateways.get(slot);
    if (gw !== undefined) {
      gw.setTokens?.(accessToken, refreshToken);
      if (gw.status !== "online") {
        await gw.start();
      }
    }
    this.tunnel.notifyManifestChanged();
  }

  async restoreAccounts() {
    const accounts = this.store.listAccounts();
    // Local auto-delete is independent of the Zalo session: start the
    // sweeper for every stored slot, including needs_login ones.
    for (const account of accounts) {
      this.startAutoDeleteSweeper(account.slot);
      this.startTtlSweeper(account.slot);
    }
    for (const account of accounts) {
      if (account.credentials_json === "") continue;
      try {
        const self: GatewaySelf = {
          uid: account.zalo_uid ?? "",
          displayName: account.display_name,
          avatarUrl: account.avatar_url,
        };
        const gw =
          account.kind === "oa" && this.factory.fromOaCredentials !== undefined
            ? this.factory.fromOaCredentials(
                JSON.parse(account.credentials_json) as OaCredentials,
                self,
                this.oaHooks(() => account.slot),
              )
            : this.factory.fromCredentials(
                JSON.parse(account.credentials_json),
                self,
              );
        this.gateways.set(account.slot, gw);
        this.wire(account.slot, gw);
        await gw.start();
      } catch (e) {
        this.store.updateAccountStatus(account.slot, "error");
        console.error(`account ${account.slot} failed to start:`, e);
      }
    }
  }

  // Durable & in-flight cliId idempotency across all send methods:
  // binds (slot, cliId) to a canonical SHA-256 request hash so reusing a
  // key for a different method, destination, or body is rejected as conflict.
  private async sendWithCliId(
    slot: string,
    cliId: string,
    method: string,
    payload: unknown,
    send: () => Promise<{ msgId: string; cliId: string }>,
  ): Promise<{ msgId: string; cliId: string }> {
    if (cliId === "") return send();
    const requestHash = sha256Hex(JSON.stringify({ method, payload }));
    const key = `${slot}:${cliId}`;
    const running = this.inflightSends.get(key);
    if (running !== undefined) {
      if (running.hash !== requestHash) {
        throw new RpcError("conflict", "cliId reused with a different request");
      }
      return running.promise;
    }
    const stored = this.store.getIdempotencyKey(slot, cliId);
    if (stored !== null) {
      if (stored.request_hash !== requestHash) {
        throw new RpcError("conflict", "cliId reused with a different request");
      }
      if (stored.state === "completed" && stored.result_json !== null) {
        return JSON.parse(stored.result_json) as { msgId: string; cliId: string };
      }
      // Pending row from a crashed prior process: reconcile from stored messages.
      const existing = this.store.getMessageByCliId(slot, cliId);
      if (existing !== null) {
        const res = { msgId: existing.msg_id, cliId };
        this.store.completeIdempotencyKey(slot, cliId, res);
        return res;
      }
    } else {
      const existing = this.store.getMessageByCliId(slot, cliId);
      if (existing !== null) {
        return { msgId: existing.msg_id, cliId };
      }
    }
    this.store.beginIdempotencyKey(slot, cliId, method, requestHash);
    const promise = send()
      .then((res) => {
        this.store.completeIdempotencyKey(slot, cliId, res);
        return res;
      })
      .catch((err) => {
        this.store.deleteIdempotencyKey(slot, cliId);
        throw err;
      })
      .finally(() => {
        if (this.inflightSends.get(key)?.promise === promise) {
          this.inflightSends.delete(key);
        }
      });
    this.inflightSends.set(key, { hash: requestHash, promise });
    return await promise;
  }

  async sendText(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    text: string,
    opts?: {
      quote?: { raw?: unknown };
      mentions?: Message["mentions"];
      styles?: StyleRun[];
      urgency?: Urgency;
      ttl?: number;
    },
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendText",
      { threadId, threadType, text, urgency: opts?.urgency ?? null, ttl: opts?.ttl ?? 0 },
      async () => {
      const res = await gw.sendText(threadId, threadType, text, opts);
      const ts = Date.now();
      const ttl = opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
      const message: Message = {
        id: res.msgId,
        // An empty cliId means "no idempotency key"; store NULL so the
        // partial unique index never sees two empty keys.
        cliId: cliId === "" ? null : cliId,
        threadId,
        threadType,
        senderId: gw.self.uid,
        senderName: gw.self.displayName,
        ts,
        isSelf: true,
        kind: "text",
        text,
        // At send time the server still has the raw payload, so store the
        // normalized quote the client renders (id, sender name, text).
        quote: normalizeQuote(opts?.quote?.raw),
        mentions: opts?.mentions,
        ...(opts?.styles !== undefined ? { styles: opts.styles } : {}),
        ...(opts?.urgency !== undefined ? { urgency: opts.urgency } : {}),
        ...(ttl !== undefined ? { ttl, expiresAt: ts + ttl } : {}),
        reactions: {},
        recalled: false,
      };
      this.persistSelf(slot, message);
      return { msgId: res.msgId, cliId };
    });
  }

  private persistSelf(slot: string, message: Message) {
    // A plausible raw for own sends so the body carries everything a later
    // quote needs; the selfListen echo replaces it on real accounts.
    if (message.raw === undefined) {
      const gw = this.gateway(slot);
      const msgTypes: Record<string, string> = {
        text: "webchat",
        image: "chat.photo",
        gif: "chat.gif",
        video: "chat.video.msg",
        file: "share.file",
        voice: "chat.voice",
        sticker: "chat.sticker",
        card: "chat.recommended",
        link: "chat.link",
        bank: "chat.bankcard",
      };
      message.raw = {
        msgId: message.id,
        cliMsgId: message.cliId ?? "",
        uidFrom: gw.self.uid,
        idTo: message.threadId,
        msgType: msgTypes[message.kind] ?? "webchat",
        ts: message.ts,
        st: 0,
        at: 0,
        cmd: 0,
        ttl: message.ttl ?? 0,
        dName: gw.self.displayName,
        content: message.kind === "text"
          ? (message.text ?? "")
          : message.card !== undefined
            ? {
                title: message.card.displayName,
                description: JSON.stringify({
                  ...(message.card.phone !== undefined
                    ? { phone: message.card.phone }
                    : {}),
                  ...(message.card.qrCodeUrl !== undefined
                    ? { qrCodeUrl: message.card.qrCodeUrl }
                    : {}),
                }),
                thumb: message.card.avatarUrl,
              }
            : message.kind === "link"
              ? {
                  title: message.attachments?.[0]?.name ?? "",
                  href: message.attachments?.[0]?.url ?? "",
                  thumb: message.attachments?.[0]?.thumbUrl ?? "",
                }
              : "",
      };
    }
    this.tx(() => {
      this.store.upsertThread({
        slot,
        threadId: message.threadId,
        type: message.threadType,
      });
      this.store.upsertMessage({
        ...messageToRow(slot, message),
        bodyJson: JSON.stringify(this.recordFor(slot, message)),
      });
      this.store.recordMediaRefs(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        messageMediaHashes(message),
      );
      this.store.updateThreadLast(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        message.ts,
      );
      this.cachedThreadName(slot, message.threadId, message.threadType);
      this.emitMessage(slot, "message.new", this.recordFor(slot, message));
      this.threadUpdated(slot, message.threadId, message.threadType);
    });
    // A conversation started by an own send has no name yet either.
    this.ensureThreadName(slot, message.threadId, message.threadType);
  }

  private mergeEcho(slot: string, message: Message) {
    // Re-seal the record from the authoritative gateway payload.
    const row = this.store.getMessage(slot, message.id);
    if (row === null) return;
    const rec = this.recordFor(slot, message) as Record<string, unknown>;
    // A receipt can fold before the self echo arrives. The echo rebuilds the
    // body from the gateway payload and carries no delivery, so keep the
    // folded state unless the echo brings a newer one.
    const prev = rowToRecord(row);
    const delivery = mergeDelivery(
      prev.delivery,
      (message as Message & { delivery?: unknown }).delivery,
    );
    if (delivery !== undefined) rec.delivery = delivery;
    this.tx(() => {
      this.store.upsertMessage({
        ...messageToRow(slot, message),
        bodyJson: JSON.stringify(rec),
      });
      this.store.recordMediaRefs(
        slot,
        message.threadId,
        message.threadType,
        message.id,
        messageMediaHashes(message),
      );
      this.emitMessage(slot, "message.updated", rec);
    });
  }

  // Persist the acting account's own reaction and broadcast message.updated.
  // Empty icon removes the user's reactions.
  async react(
    slot: string,
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    icon: string,
  ) {
    const gw = this.gateway(slot);
    await gw.react(
      msgId,
      threadId,
      threadType,
      icon,
      this.store.messageRef(slot, msgId),
    );
    const row = this.store.getMessage(slot, msgId);
    if (row === null) return;
    this.tx(() => {
      const rec = rowToRecord(row);
      applyReaction(rec, icon, gw.self.uid);
      this.store.updateMessageBody(slot, msgId, JSON.stringify(rec));
      this.emitMessage(slot, "message.updated", rec);
    });
  }

  // Delete-for-me: row gone, its content scrubbed from the event log,
  // and a sequenced message.deleted for every device.
  async deleteMessage(
    slot: string,
    msgId: string,
    threadId: string,
    threadType: ThreadType,
  ) {
    const gw = this.gateway(slot);
    const row = this.store.getMessage(slot, msgId);
    if (
      row === null ||
      row.thread_id !== threadId ||
      row.thread_type !== threadType
    ) {
      throw new RpcError("not_found", msgId);
    }
    await gw.deleteMessage(
      msgId,
      threadId,
      threadType,
      this.store.messageRef(slot, msgId),
    );
    let seq = 0;
    let orphanHashes: string[] = [];
    this.tx(() => {
      this.store.deleteMessage(slot, msgId);
      orphanHashes = this.store.releaseMediaRefsForMessages(slot, [msgId]);
      const row = this.store.appendEvent(slot, "message.deleted", {
        threadId,
        msgId,
      });
      seq = row.seq;
      this.threadUpdated(slot, threadId, threadType);
    });
    if (orphanHashes.length > 0) {
      await deleteMediaObjects(this.store.dir, slot, orphanHashes);
    }
    this.tunnel.broadcastAccount(slot, "message.deleted", { threadId, msgId }, seq);
    this.store.checkpoint();
  }

  // messages.deleteForAll: a group owner/deputy deletes another member's
  // message for everyone. Authorization uses Zalo's group info and the
  // account's own uid; the local record is removed exactly like a
  // delete-for-me (row gone, event content scrubbed, message.deleted).
  async deleteForAll(
    slot: string,
    msgId: string,
    threadId: string,
    threadType: ThreadType,
  ) {
    const gw = this.gateway(slot);
    const row = this.store.getMessage(slot, msgId);
    if (row === null || row.thread_id !== threadId) {
      throw new RpcError("not_found", msgId);
    }
    if (threadType !== "group" || row.thread_type !== "group") {
      throw new RpcError(
        "bad_request",
        "delete for everyone is only available in groups",
      );
    }
    if (row.is_self) {
      throw new RpcError("bad_request", "use recall for your own messages");
    }
    const info = await gw.groupInfo(threadId);
    const uid = gw.self.uid;
    if (
      uid === "" ||
      (info.ownerId !== uid && !(info.adminIds ?? []).includes(uid))
    ) {
      throw new RpcError(
        "forbidden",
        "only the group owner or a deputy can delete this message for everyone",
      );
    }
    await gw.deleteMessageForAll(
      msgId,
      threadId,
      "group",
      this.store.messageRef(slot, msgId),
    );
    let seq = 0;
    let orphanHashes: string[] = [];
    this.tx(() => {
      this.store.deleteMessage(slot, msgId);
      orphanHashes = this.store.releaseMediaRefsForMessages(slot, [msgId]);
      const evt = this.store.appendEvent(slot, "message.deleted", {
        threadId,
        msgId,
      });
      seq = evt.seq;
      this.threadUpdated(slot, threadId, "group");
    });
    if (orphanHashes.length > 0) {
      await deleteMediaObjects(this.store.dir, slot, orphanHashes);
    }
    this.tunnel.broadcastAccount(
      slot,
      "message.deleted",
      { threadId, msgId },
      seq,
    );
    this.store.checkpoint();
  }

  async setPinned(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    pinned: boolean,
  ) {
    const gw = this.gateway(slot);
    await gw.setPinned(threadId, threadType, pinned);
    this.tx(() => {
      this.store.setThreadFlag(slot, threadId, threadType, "pinned", pinned);
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
  }

  async setMuted(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    muted: boolean,
  ) {
    const gw = this.gateway(slot);
    await gw.setMuted(threadId, threadType, muted);
    this.tx(() => {
      this.store.setThreadFlag(slot, threadId, threadType, "muted", muted);
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
  }

  async markUnreadThread(slot: string, threadId: string, threadType: ThreadType) {
    const gw = this.gateway(slot);
    await gw.markUnread(threadId, threadType);
    this.tx(() => {
      this.store.markUnread(slot, threadId, threadType);
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
  }

  // threads.delete: the conversation is removed on Zalo with the stored
  // last-message reference, then everything local is purged. A thread with
  // no last message has no reference to send, so the remote delete is
  // skipped rather than sending an empty conver triple.
  async deleteThread(slot: string, threadId: string, threadType: ThreadType) {
    const gw = this.gateway(slot);
    const thread = this.store.getThread(slot, threadId, threadType);
    if (thread === null) throw new RpcError("not_found", threadId);
    const lastRef =
      thread.last_msg_id !== null && thread.last_msg_id !== undefined
        ? this.store.messageRef(slot, String(thread.last_msg_id))
        : null;
    if (lastRef !== null && lastRef !== undefined) {
      await gw.deleteConversation(threadId, threadType, lastRef);
    }
    this.tx(() => {
      this.store.deleteThread(slot, threadId, threadType);
      this.store.releaseMediaRefsForThread(slot, threadId, threadType);
      const row = this.store.appendEvent(slot, "thread.deleted", {
        threadId,
        threadType,
      });
      this.tunnel.broadcastAccount(
        slot,
        "thread.deleted",
        { threadId, threadType },
        row.seq,
      );
    });
    // Cache keys contain only a URL hash, not a thread id, and sealed rows
    // cannot be searched for ownership. Purge this slot's whole media/tmp
    // scope so no thread artifact survives; other accounts are untouched.
    await clearAccountMedia(this.store.dir, slot);
    this.store.checkpoint();
    this.tunnel.notifyManifestChanged();
  }

  async forwardMessage(
    slot: string,
    msgId: string,
    threadId: string,
    threadType: ThreadType,
    to: { threadId: string; threadType: ThreadType }[],
    raw?: string,
  ) {
    if (to.length === 0) throw new RpcError("invalid_params", "no destinations");
    if (to.length > 20) {
      throw new RpcError("invalid_params", "at most 20 destinations");
    }
    const gw = this.gateway(slot);
    const row = this.store.getMessage(slot, msgId);
    if (row === null) throw new RpcError("not_found", msgId);
    const rec = rowToRecord(row);
    // Content is sealed at rest; the client supplies the plaintext to send.
    const text = raw ?? (typeof rec.body === "object" && rec.body !== null
      ? String((rec.body as Record<string, unknown>).text ?? "")
      : "");
    if (text === "") {
      throw new RpcError("invalid_params", "message content unavailable");
    }
    await gw.forward(
      { message: text, reference: this.forwardReference(slot, msgId, rec) },
      to,
    );
    this.store.checkpoint();
  }

  // zca-js only sends msgInfo.reference (and the forwarded marker) when the
  // payload carries one; its reference is {id, ts, logSrcType, fwLvl}. The
  // id/ts come from the stored raw message. logSrcType and fwLvl are the web
  // client's forward defaults (zca-js issue #196) when the raw payload does
  // not carry them.
  private forwardReference(
    slot: string,
    msgId: string,
    rec: Record<string, unknown>,
  ) {
    const ref = (this.store.messageRef(slot, msgId) ?? {}) as Record<
      string,
      unknown
    >;
    const body = rec.body;
    const bodyRaw =
      body !== null && typeof body === "object"
        ? (body as Record<string, unknown>).raw
        : undefined;
    const raw =
      bodyRaw !== null && typeof bodyRaw === "object"
        ? (bodyRaw as Record<string, unknown>)
        : {};
    const field = (key: string) => raw[key] ?? ref[key];
    return {
      id: String(field("msgId") ?? rec.id ?? ""),
      ts: Number(field("ts") ?? rec.ts ?? 0),
      logSrcType: Number(field("logSrcType") ?? 0),
      fwLvl: Number(field("fwLvl") ?? 1),
    };
  }

  // users.get with a 24 h profiles cache; unknown ids come back with an
  // empty displayName instead of failing the batch.
  async usersGet(slot: string, uids: string[]) {
    const out: { uid: string; displayName: string; avatarUrl: string }[] = [];
    const missing: string[] = [];
    for (const uid of uids) {
      const hit = this.store.getProfileFresh(slot, uid, "user", 24 * 3600 * 1000);
      if (hit !== null) {
        out.push({ uid, displayName: hit.name, avatarUrl: hit.avatar_url });
      } else {
        missing.push(uid);
      }
    }
    if (missing.length > 0) {
      const gw = this.gateway(slot);
      const infos = await gw.userInfo(missing);
      const seen = new Set(infos.map((i) => i.uid));
      for (const info of infos) {
        this.store.upsertProfile({
          slot,
          uid: info.uid,
          kind: "user",
          name: info.displayName,
          avatarUrl: info.avatarUrl,
          fetchedAt: Date.now(),
        });
        out.push(info);
      }
      for (const uid of missing) {
        if (!seen.has(uid)) {
          this.store.upsertProfile({
            slot,
            uid,
            kind: "user",
            name: "",
            avatarUrl: "",
            fetchedAt: Date.now(),
          });
          out.push({ uid, displayName: "", avatarUrl: "" });
        }
      }
    }
    return out;
  }

  // groups.info with member profiles; member display names land in the
  // profiles cache so users.get resolves them too.
  async groupInfoMembers(slot: string, groupId: string) {
    const gw = this.gateway(slot);
    const info = await gw.groupInfo(groupId);
    let profiles: UserInfo[] = [];
    if (info.memberIds.length > 0) {
      try {
        profiles = await gw.groupMembersInfo(info.memberIds);
      } catch {
        profiles = [];
      }
    }
    const byUid = new Map(profiles.map((p) => [p.uid, p]));
    // Names/avatars already carried by the gateway (zca currentMems) fill in
    // when a profile lookup fails or returns an empty row.
    const seeds = new Map((info.members ?? []).map((m) => [m.uid, m]));
    const members = info.memberIds.map((uid) => {
      const p = byUid.get(uid);
      const seed = seeds.get(uid);
      return {
        uid,
        displayName: p?.displayName || seed?.displayName || "",
        avatarUrl: p?.avatarUrl || seed?.avatarUrl || "",
        role: (uid === info.ownerId
          ? "owner"
          : (info.adminIds ?? []).includes(uid)
            ? "deputy"
            : "member") as "owner" | "deputy" | "member",
      };
    });
    for (const m of members) {
      if (m.displayName !== "") {
        this.store.upsertProfile({
          slot,
          uid: m.uid,
          kind: "user",
          name: m.displayName,
          avatarUrl: m.avatarUrl,
          fetchedAt: Date.now(),
        });
      }
    }
    return { ...info, members };
  }

  // accounts.logout: log out at Zalo, wipe the credentials, keep the row
  // as needs_login so the client can re-add cleanly.
  async logoutAccount(slot: string) {
    // Let a queued sweep finish before the session is torn down, so it
    // cannot write events after the account has been stopped.
    await this.awaitSweeps(slot);
    const gw = this.gateways.get(slot);
    if (gw !== undefined) {
      try {
        await gw.logout();
      } catch {}
      this.gateways.delete(slot);
      try {
        await gw.stop();
      } catch {}
    }
    this.tx(() => {
      this.store.updateAccountCredentials(slot, "");
      this.store.updateAccountStatus(slot, "needs_login");
      this.emit(slot, "account.status", { status: "needs_login" });
    });
    this.store.reclaimDeletedData();
    await clearAccountMedia(this.store.dir, slot, { retire: true });
    this.tunnel.notifyManifestChanged();
  }

  private foldReceipt(
    slot: string,
    t: {
      threadId: string;
      threadType: ThreadType;
      kind: "seen" | "delivered";
      userIds: string[];
      msgId: string;
    },
  ) {
    const row = this.store.getMessage(slot, t.msgId);
    if (row === null || !row.is_self) return;
    const rec = rowToRecord(row);
    const prev = (rec.delivery ?? {}) as Record<string, unknown>;
    const rank: Record<string, number> = { sent: 0, delivered: 1, seen: 2 };
    const cur = String(prev.state ?? "sent");
    const next = t.kind === "seen" ? "seen" : "delivered";
    if ((rank[next] ?? 0) <= (rank[cur] ?? 0)) return;
    const delivery: Record<string, unknown> = { state: next };
    if (t.threadType === "group" && next === "seen") {
      delivery.seenBy = Number(prev.seenBy ?? 0) + t.userIds.length;
    } else if (prev.seenBy !== undefined) {
      delivery.seenBy = prev.seenBy;
    }
    rec.delivery = delivery;
    this.tx(() => {
      this.store.updateMessageBody(slot, t.msgId, JSON.stringify(rec));
      this.emitMessage(slot, "message.updated", rec);
    });
  }

  // Cheap group listener events mapped onto thread state: rename/avatar/
  // member-count changes become a thread.updated. Membership and setting
  // changes also invalidate the cached roster, which is refetched in the
  // background so groups.info and users.get do not serve stale data.
  private groupEvent(slot: string, e: unknown) {
    const ev = e as Record<string, unknown>;
    const data = (ev.data ?? {}) as Record<string, unknown>;
    const gid = String(data.groupId ?? data.grid ?? "");
    if (gid === "") return;
    const row = this.store.getThread(slot, gid, "group");
    if (row === null) return;
    const name = String(data.groupName ?? data.name ?? row.name);
    const avatar = String(data.avt ?? data.avatar ?? row.avatar_url);
    const profileChanged = name !== row.name || avatar !== row.avatar_url;
    const members = Array.isArray(data.updateMembers)
      ? data.updateMembers
      : [];
    const settingChanged =
      data.groupSetting !== null && data.groupSetting !== undefined;
    if (!profileChanged && members.length === 0 && !settingChanged) return;
    if (profileChanged) {
      this.tx(() => {
        this.store.updateThreadProfile(slot, gid, "group", name, avatar);
        this.threadUpdated(slot, gid, "group");
      });
    }
    if (members.length > 0 || settingChanged) {
      this.refreshGroupMembers(slot, gid);
      // Membership changes carry no member list of their own; tell devices
      // to refetch instead of inventing members.
      if (!profileChanged) this.threadUpdated(slot, gid, "group");
    }
  }

  // A join/leave/role or setting change makes the cached roster stale.
  // Refetch it off the listener; a failure keeps the old cache and never
  // blocks the event stream.
  private refreshGroupMembers(slot: string, groupId: string) {
    const key = `${slot}:${groupId}`;
    if (this.groupMemberRefreshes.has(key)) return;
    this.groupMemberRefreshes.add(key);
    void (async () => {
      try {
        const info = await this.groupInfoMembers(slot, groupId);
        const row = this.store.getThread(slot, groupId, "group");
        if (row === null) return;
        const name = info.name !== "" ? info.name : String(row.name);
        const avatar =
          info.avatarUrl !== "" ? info.avatarUrl : String(row.avatar_url);
        if (name === row.name && avatar === row.avatar_url) return;
        this.tx(() => {
          this.store.updateThreadProfile(slot, groupId, "group", name, avatar);
          this.threadUpdated(slot, groupId, "group");
        });
      } catch {
        // Offline or the group is gone; the next event or groups.info retries.
      } finally {
        this.groupMemberRefreshes.delete(key);
      }
    })();
  }

  // Post-connect: pull Zalo's pinned/muted truth into local threads.
  private async syncConversationState(slot: string) {
    const gw = this.gateways.get(slot);
    if (gw === undefined) return;
    try {
      const state = await gw.syncConversationState();
      const keys = (refs: ConversationRef[]) =>
        new Set(refs.map((t) => `${t.threadType}:${t.threadId}`));
      const pinned = state.pinned === undefined ? null : keys(state.pinned);
      const muted = state.muted === undefined ? null : keys(state.muted);
      // A missing section means its endpoint failed; keep local values.
      const hidden =
        state.hidden === undefined ? null : keys(state.hidden);
      const archived =
        state.archived === undefined ? null : keys(state.archived);
      const autoDelete =
        state.autoDelete === undefined
          ? null
          : new Map(
              state.autoDelete.map((t) => [
                `${t.threadType}:${t.threadId}`,
                t.ttl,
              ]),
            );
      this.tx(() => {
        for (const row of this.store.listThreads(slot)) {
          const key = `${row.type}:${row.thread_id}`;
          const p = pinned === null ? !!row.pinned : pinned.has(key);
          const m = muted === null ? !!row.muted : muted.has(key);
          const h = hidden === null ? !!row.hidden : hidden.has(key);
          const a = archived === null ? !!row.archived : archived.has(key);
          const curTtl = Number(row.auto_delete_ttl ?? 0);
          const ttl =
            autoDelete === null ? curTtl : (autoDelete.get(key) ?? 0);
          if (
            p === !!row.pinned &&
            m === !!row.muted &&
            h === !!row.hidden &&
            a === !!row.archived &&
            ttl === curTtl
          ) {
            continue;
          }
          const threadId = String(row.thread_id);
          const type = String(row.type) as ThreadType;
          if (p !== !!row.pinned) {
            this.store.setThreadFlag(slot, threadId, type, "pinned", p);
          }
          if (m !== !!row.muted) {
            this.store.setThreadFlag(slot, threadId, type, "muted", m);
          }
          if (h !== !!row.hidden) {
            this.store.setThreadFlag(slot, threadId, type, "hidden", h);
          }
          if (a !== !!row.archived) {
            this.store.setThreadFlag(slot, threadId, type, "archived", a);
          }
          if (ttl !== curTtl) {
            this.store.setThreadTtl(slot, threadId, type, ttl);
          }
          this.threadUpdated(slot, threadId, type);
        }
      });
      // Threads created before names were resolvable (offline injects,
      // pre-profile-cache data) get their names filled in on connect.
      for (const row of this.store.listThreads(slot)) {
        if (row.name === "") {
          this.ensureThreadName(
            slot,
            String(row.thread_id),
            String(row.type) as ThreadType,
          );
        }
      }
    } catch {}
  }

  // ---- hidden conversations ----

  async hiddenList(slot: string): Promise<HiddenConversations> {
    return this.gateway(slot).hiddenConversations();
  }

  async setHidden(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    hidden: boolean,
  ) {
    const gw = this.gateway(slot);
    await gw.setHiddenConversations([{ threadId, threadType }], hidden);
    this.tx(() => {
      this.store.setThreadFlag(slot, threadId, threadType, "hidden", hidden);
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
  }

  async setHiddenPin(slot: string, pin: string) {
    await this.gateway(slot).setHiddenPin(pin);
  }

  async resetHiddenPin(slot: string) {
    await this.gateway(slot).resetHiddenPin();
  }

  // ---- archived conversations ----

  async archiveList(slot: string): Promise<ArchivedChatList> {
    return this.gateway(slot).archivedChatList();
  }

  async setArchived(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    archived: boolean,
  ): Promise<{ needResync: boolean; version: number }> {
    const gw = this.gateway(slot);
    const res = await gw.updateArchivedChatList(archived, [
      { threadId, threadType },
    ]);
    this.tx(() => {
      this.store.setThreadFlag(
        slot,
        threadId,
        threadType,
        "archived",
        archived,
      );
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
    // Zalo reports needResync when its archive version moved underneath
    // us; pull the authoritative conversation state now instead of
    // waiting for the next reconnect.
    if (res.needResync) await this.syncConversationState(slot);
    return res;
  }

  // ---- labels ----

  // One queue per account: read-modify-write label updates never
  // interleave, so a stale version is always detected.
  private serializedLabels<T>(
    slot: string,
    fn: () => Promise<T>,
  ): Promise<T> {
    const prev = this.labelTails.get(slot) ?? Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    this.labelTails.set(slot, tail);
    void tail.finally(() => {
      if (this.labelTails.get(slot) === tail) this.labelTails.delete(slot);
    });
    return run;
  }

  labelsList(slot: string): Promise<LabelsState> {
    return this.serializedLabels(slot, async () => {
      const state = await this.gateway(slot).labels();
      this.tx(() => {
        this.store.replaceLabels(
          slot,
          state.labels.map(labelRow),
          state.version,
          state.lastUpdateTime,
        );
      });
      return state;
    });
  }

  updateLabels(
    slot: string,
    labels: Label[],
    version: number,
  ): Promise<LabelsState> {
    return this.serializedLabels(slot, async () => {
      const gw = this.gateway(slot);
      const current = await gw.labels();
      if (current.version !== version) {
        throw new RpcError(
          "conflict",
          `labels version ${current.version} != ${version}`,
        );
      }
      const state = await gw.updateLabels(labels, version);
      this.tx(() => {
        this.store.replaceLabels(
          slot,
          state.labels.map(labelRow),
          state.version,
          state.lastUpdateTime,
        );
        this.emit(slot, "labels.changed", { version: state.version });
      });
      return state;
    });
  }

  // ---- auto-delete ----

  autoDeleteChat(slot: string): Promise<AutoDeleteChat> {
    return this.gateway(slot).autoDeleteChat();
  }

  async setAutoDelete(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    ttl: number,
  ) {
    if (!(AUTO_DELETE_TTLS as readonly number[]).includes(ttl)) {
      throw new RpcError("bad_request", "unsupported auto-delete ttl");
    }
    const gw = this.gateway(slot);
    await gw.updateAutoDeleteChat(threadId, threadType, ttl);
    this.tx(() => {
      this.store.setThreadTtl(slot, threadId, threadType, ttl);
      this.threadUpdated(slot, threadId, threadType);
    });
    // A newly shortened TTL applies to already stored messages at once.
    if (ttl > 0) await this.sweepAutoDelete(slot);
  }

  // ---- linked Zalo devices ----

  linkedDevices(slot: string): Promise<LinkedDevices> {
    return this.gateway(slot).linkedDevices();
  }

  // ---- local expiry sweepers ----

  startAutoDeleteSweeper(slot: string) {
    if (this.sweepMs <= 0 || this.sweepTimers.has(slot)) return;
    const timer = setInterval(() => {
      void this.sweepAutoDelete(slot).catch(() => {});
    }, this.sweepMs);
    timer.unref?.();
    this.sweepTimers.set(slot, timer);
    void this.sweepAutoDelete(slot).catch(() => {});
  }

  stopAutoDeleteSweeper(slot: string) {
    const timer = this.sweepTimers.get(slot);
    if (timer !== undefined) {
      clearInterval(timer);
      this.sweepTimers.delete(slot);
    }
  }

  hasAutoDeleteSweeper(slot: string): boolean {
    return this.sweepTimers.has(slot);
  }

  // Per-message TTL sweeper. Independent of auto-delete: it deletes rows
  // whose own expires_at passed, whatever the conversation TTL says.
  startTtlSweeper(slot: string) {
    if (this.ttlSweepMs <= 0 || this.ttlTimers.has(slot)) return;
    const timer = setInterval(() => {
      void this.sweepTtl(slot).catch(() => {});
    }, this.ttlSweepMs);
    timer.unref?.();
    this.ttlTimers.set(slot, timer);
    void this.sweepTtl(slot).catch(() => {});
  }

  stopTtlSweeper(slot: string) {
    const timer = this.ttlTimers.get(slot);
    if (timer !== undefined) {
      clearInterval(timer);
      this.ttlTimers.delete(slot);
    }
  }

  hasTtlSweeper(slot: string): boolean {
    return this.ttlTimers.has(slot);
  }

  // Both sweep kinds run on one chain per slot so they never scan the same
  // rows at once; each kind additionally shares its own in-flight promise
  // so overlapping timer ticks do one scan, not two.
  private autoSweeps = new Map<string, Promise<number>>();
  private ttlSweeps = new Map<string, Promise<number>>();

  private enqueueSweep<T>(slot: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.sweepChains.get(slot) ?? Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    this.sweepChains.set(slot, tail);
    void tail.finally(() => {
      if (this.sweepChains.get(slot) === tail) this.sweepChains.delete(slot);
    });
    return run;
  }

  // Wait until no sweep is queued for the slot. Called before account rows
  // are deleted or the manager closes, so an in-flight sweep cannot append
  // events/event_counters for a slot that is going away.
  private async awaitSweeps(slot: string): Promise<void> {
    for (;;) {
      const pending = [
        this.sweepChains.get(slot),
        this.autoSweeps.get(slot),
        this.ttlSweeps.get(slot),
      ].filter((p): p is Promise<unknown> => p !== undefined);
      if (pending.length === 0) return;
      await Promise.allSettled(pending);
    }
  }

  sweepAutoDelete(slot: string): Promise<number> {
    const running = this.autoSweeps.get(slot);
    if (running !== undefined) return running;
    let p: Promise<number>;
    p = this.enqueueSweep(slot, () => this.runAutoDeleteSweep(slot)).finally(
      () => {
        if (this.autoSweeps.get(slot) === p) this.autoSweeps.delete(slot);
      },
    );
    this.autoSweeps.set(slot, p);
    return p;
  }

  sweepTtl(slot: string): Promise<number> {
    const running = this.ttlSweeps.get(slot);
    if (running !== undefined) return running;
    let p: Promise<number>;
    p = this.enqueueSweep(slot, () => this.runTtlSweep(slot)).finally(() => {
      if (this.ttlSweeps.get(slot) === p) this.ttlSweeps.delete(slot);
    });
    this.ttlSweeps.set(slot, p);
    return p;
  }

  // Deletes messages past their conversation TTL, scrubs their event-log
  // content, emits sequenced deletions plus thread.updated, and flushes
  // the WAL so the content is gone from disk.
  private async runAutoDeleteSweep(slot: string): Promise<number> {
    const expired = this.store.expiredMessages(slot, Date.now());
    return this.deleteExpired(slot, expired);
  }

  // Same invariants for per-message self-destruct.
  private async runTtlSweep(slot: string): Promise<number> {
    const expired = this.store.expiredTtlMessages(slot, Date.now());
    return this.deleteExpired(slot, expired);
  }

  private async deleteExpired(
    slot: string,
    expired: { msg_id: string; thread_id: string; thread_type: string }[],
  ): Promise<number> {
    if (expired.length === 0) return 0;
    const deleted: { threadId: string; msgId: string; seq: number }[] = [];
    const touched = new Map<
      string,
      { threadId: string; threadType: ThreadType }
    >();
    let orphanHashes: string[] = [];
    this.tx(() => {
      const ids = expired.map((m) => m.msg_id);
      this.store.deleteMessages(slot, ids);
      orphanHashes = this.store.releaseMediaRefsForMessages(slot, ids);
      for (const row of expired) {
        const evt = this.store.appendEvent(slot, "message.deleted", {
          threadId: row.thread_id,
          msgId: row.msg_id,
        });
        deleted.push({
          threadId: row.thread_id,
          msgId: row.msg_id,
          seq: evt.seq,
        });
        touched.set(`${row.thread_type}:${row.thread_id}`, {
          threadId: row.thread_id,
          threadType: row.thread_type as ThreadType,
        });
      }
      for (const t of touched.values()) {
        this.store.refreshThreadLast(slot, t.threadId, t.threadType);
        this.threadUpdated(slot, t.threadId, t.threadType);
      }
    });
    if (orphanHashes.length > 0) {
      await deleteMediaObjects(this.store.dir, slot, orphanHashes);
    }
    for (const d of deleted) {
      this.tunnel.broadcastAccount(
        slot,
        "message.deleted",
        { threadId: d.threadId, msgId: d.msgId },
        d.seq,
      );
    }
    this.store.checkpoint();
    return deleted.length;
  }

  // On-demand group history: when messages.list pages past the oldest
  // stored message of a group, the newest `stored + want` messages are
  // pulled from Zalo (the endpoint has no cursor), new ones persisted
  // sealed like live traffic. A group is exhausted for this process once
  // Zalo reports no more or a fetch adds nothing; concurrent pages share
  // one in-flight fetch. Resolves to whether older history may remain.
  private groupHistoryExhausted = new Set<string>();
  private groupHistoryInflight = new Map<string, Promise<boolean>>();

  maybeFetchGroupHistory(
    slot: string,
    groupId: string,
    want: number,
  ): Promise<boolean> {
    const key = `${slot}:${groupId}`;
    if (this.groupHistoryExhausted.has(key)) return Promise.resolve(false);
    const inflight = this.groupHistoryInflight.get(key);
    if (inflight !== undefined) return inflight;
    const gw = this.gateways.get(slot);
    if (gw?.groupHistory === undefined) return Promise.resolve(false);
    const fetchHistory = gw.groupHistory.bind(gw);
    const p = (async () => {
      try {
        const stored = this.store.countMessages(slot, groupId, "group");
        const res = await fetchHistory(
          groupId,
          Math.min(stored + want, GROUP_HISTORY_MAX),
        );
        let added = 0;
        for (const m of res.messages) {
          if (m.threadId !== groupId || m.threadType !== "group") continue;
          if (this.ingestHistory(slot, m, { unread: false })) added++;
        }
        if (added > 0) {
          this.threadUpdated(slot, groupId, "group");
          this.store.checkpoint();
        }
        const more =
          res.more && added > 0 && stored + added < GROUP_HISTORY_MAX;
        if (!more) this.groupHistoryExhausted.add(key);
        return more;
      } catch {
        // Offline or the endpoint failed: report no more for this page;
        // a later page asks again.
        return false;
      } finally {
        this.groupHistoryInflight.delete(key);
      }
    })();
    this.groupHistoryInflight.set(key, p);
    return p;
  }

  // users.avatar: full-size avatar url, cached for 24 h in profiles
  // (kind full_avatar).
  async userAvatar(slot: string, uid: string): Promise<string> {
    const hit = this.store.getProfileFresh(
      slot,
      uid,
      "full_avatar",
      24 * 3600 * 1000,
    );
    if (hit !== null) return hit.avatar_url;
    const gw = this.gateway(slot);
    if (gw.fullAvatar === undefined) {
      throw new RpcError("not_supported", "full avatar unavailable");
    }
    const url = await gw.fullAvatar(uid);
    this.store.upsertProfile({
      slot,
      uid,
      kind: "full_avatar",
      name: "",
      avatarUrl: url,
      fetchedAt: Date.now(),
    });
    return url;
  }

  private keepAliveTimer: ReturnType<typeof setInterval> | null = null;

  // Stops every gateway (sockets, poll and retry timers) so shutdown
  // leaves no session able to reconnect or poll behind our back.
  async close(): Promise<void> {
    if (this.keepAliveTimer !== null) {
      clearInterval(this.keepAliveTimer);
      this.keepAliveTimer = null;
    }
    for (const slot of new Set([
      ...this.sweepTimers.keys(),
      ...this.ttlTimers.keys(),
    ])) {
      this.stopAutoDeleteSweeper(slot);
      this.stopTtlSweeper(slot);
    }
    // Shutdown must not race a sweep into writing after the caller has
    // closed the store.
    const sweeping = new Set([
      ...this.sweepChains.keys(),
      ...this.autoSweeps.keys(),
      ...this.ttlSweeps.keys(),
    ]);
    await Promise.all([...sweeping].map((slot) => this.awaitSweeps(slot)));
    await Promise.all(
      [...this.gateways.values()].map((gw) =>
        gw.stop().catch(() => {}),
      ),
    );
    for (const slot of this.gateways.keys()) {
      this.calls.clearSlot(slot);
    }
    this.gateways.clear();
  }

  // zca-js never pings the HTTP keepalive endpoint itself; a session left
  // idle long enough is treated as expired. Every 5 minutes while online.
  private startKeepAlive(slot: string) {
    this.keepAliveTimer ??= setInterval(() => {
      for (const [s, gw] of this.gateways) {
        if (gw.status === "online") {
          gw.keepAlive().catch(() => {});
        }
      }
      void slot;
    }, 5 * 60 * 1000);
    this.keepAliveTimer.unref?.();
  }

  async markSeen(slot: string, threadId: string, threadType: ThreadType) {
    const gw = this.gateway(slot);
    await gw.markSeen(
      threadId,
      threadType,
      this.store.latestIncomingRef(slot, threadId),
    );
    const row = this.store.getThread(slot, threadId, threadType);
    if (row !== null && row.marked_unread) {
      try {
        await gw.removeUnreadMark(threadId, threadType);
      } catch {}
    }
    this.tx(() => {
      this.store.clearUnread(slot, threadId, threadType);
      this.store.setThreadFlag(slot, threadId, threadType, "marked_unread", false);
      this.threadUpdated(slot, threadId, threadType);
    });
    this.tunnel.notifyManifestChanged();
  }

  async sendMedia(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    kind: "image" | "video" | "file" | "voice" | "gif",
    file: { name: string; path: string; contentType?: string },
    caption?: string,
    opts?: { ttl?: number; urgency?: Urgency },
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendMedia",
      { threadId, threadType, kind, name: file.name, caption: caption ?? "" },
      async () => {
        const res = await gw.sendMedia(
        threadId,
        threadType,
        kind,
        file,
        caption,
        cliId,
        opts,
      );
      // zca-js routes a `.gif` attachment to the gif upload whatever the
      // requested kind was; mirror that in the local record.
      const recordKind =
        kind === "image" && /\.gif$/i.test(file.name) ? "gif" : kind;
      const ts = Date.now();
      const ttl = opts?.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
      const message: Message = {
        id: res.msgId,
        cliId: res.cliId === "" ? null : res.cliId,
        threadId,
        threadType,
        senderId: gw.self.uid,
        senderName: gw.self.displayName,
        ts,
        isSelf: true,
        kind: recordKind,
        text: caption,
        attachments: [
          {
            kind: recordKind,
            url: "",
            name: file.name,
            size: Bun.file(file.path).size,
          },
        ],
        ...(opts?.urgency !== undefined ? { urgency: opts.urgency } : {}),
        ...(ttl !== undefined ? { ttl, expiresAt: ts + ttl } : {}),
        reactions: {},
        recalled: false,
      };
      this.persistSelf(slot, message);
      return { msgId: res.msgId, cliId: res.cliId };
    });
  }

  async sendSticker(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    sticker: Message["sticker"],
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendSticker",
      { threadId, threadType, id: sticker!.id, cateId: sticker!.cateId },
      async () => {
        const res = await gw.sendSticker(threadId, threadType, sticker!);
      const message: Message = {
        id: res.msgId,
        cliId: cliId === "" ? null : cliId,
        threadId,
        threadType,
        senderId: gw.self.uid,
        senderName: gw.self.displayName,
        ts: Date.now(),
        isSelf: true,
        kind: "sticker",
        sticker,
        reactions: {},
        recalled: false,
      };
      this.persistSelf(slot, message);
      return { msgId: res.msgId, cliId };
    });
  }

  // messages.sendCard: same cliId idempotency as the other sends; the
  // optimistic record carries a typed card body from the profiles cache
  // and the selfListen echo replaces it with Zalo's authoritative one.
  async sendCard(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    card: { userId: string; phoneNumber?: string; ttl?: number },
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendCard",
      { threadId, threadType, userId: card.userId, phoneNumber: card.phoneNumber ?? "" },
      async () => {
        const res = await gw.sendCard(threadId, threadType, card);
      const profile = this.store.getProfile(slot, card.userId, "user");
      const body: ContactCard = {
        uid: card.userId,
        displayName: profile?.name ?? "",
        avatarUrl: profile?.avatar_url ?? "",
        ...(card.phoneNumber !== undefined ? { phone: card.phoneNumber } : {}),
      };
      const message: Message = {
        id: res.msgId,
        cliId: cliId === "" ? null : cliId,
        threadId,
        threadType,
        senderId: gw.self.uid,
        senderName: gw.self.displayName,
        ts: Date.now(),
        isSelf: true,
        kind: "card",
        card: body,
        reactions: {},
        recalled: false,
      };
      this.persistSelf(slot, message);
      return { msgId: res.msgId, cliId };
    });
  }

  // ---- link previews ----

  parseLink(slot: string, link: string): Promise<LinkPreview> {
    return this.gateway(slot).parseLink(link);
  }

  // sendLink is idempotent by cliId. The optimistic record carries the
  // parsed preview so the bubble renders before the selfListen echo.
  async sendLink(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    opts: { link: string; msg?: string; ttl?: number },
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendLink",
      { threadId, threadType, link: opts.link, msg: opts.msg ?? "" },
      async () => {
        const preview = await gw.parseLink(opts.link);
      const res = await gw.sendLink(threadId, threadType, opts);
      const ts = Date.now();
      const ttl = opts.ttl !== undefined && opts.ttl > 0 ? opts.ttl : undefined;
      const message: Message = {
        id: res.msgId,
        // An empty cliId means "no idempotency key"; store NULL so the
        // partial unique index never sees two empty keys.
        cliId: cliId === "" ? null : cliId,
        threadId,
        threadType,
        senderId: gw.self.uid,
        senderName: gw.self.displayName,
        ts,
        isSelf: true,
        kind: "link",
        text: opts.msg !== undefined && opts.msg !== "" ? opts.msg : preview.title,
        attachments: [
          {
            kind: "link",
            url: preview.href !== "" ? preview.href : opts.link,
            thumbUrl: preview.thumbUrl,
            name: preview.title,
          },
        ],
        ...(ttl !== undefined ? { ttl, expiresAt: ts + ttl } : {}),
        reactions: {},
        recalled: false,
      };
      this.persistSelf(slot, message);
      return { msgId: res.msgId, cliId };
    });
  }

  // ---- bank cards and accounts ----

  bankList(slot: string): Promise<BankInfo[]> {
    return this.gateway(slot).bankList();
  }

  bankAccounts(
    slot: string,
    page: number,
    limit: number,
  ): Promise<BankAccounts> {
    return this.gateway(slot).bankAccounts(page, limit);
  }

  // sendBankCard's real response is empty: serialize through durable
  // sendWithCliId BEFORE awaiting the gateway so concurrent retries and
  // restarts never send twice.
  async sendBankCard(
    slot: string,
    threadId: string,
    threadType: ThreadType,
    cliId: string,
    card: { bin: number; accountNumber: string; holderName?: string },
  ) {
    const gw = this.gateway(slot);
    return await this.sendWithCliId(
      slot,
      cliId,
      "sendBankCard",
      {
        threadId,
        threadType,
        bin: card.bin,
        accountNumber: card.accountNumber,
        holderName: card.holderName ?? "",
      },
      async () => {
        const res = await gw.sendBankCard(threadId, threadType, card);
        return { msgId: res.msgId, cliId };
      },
    );
  }

  // ---- quick messages ----

  quickMessages(slot: string): Promise<QuickMessages> {
    return this.gateway(slot).quickMessages();
  }

  addQuickMessage(
    slot: string,
    draft: QuickMessageDraft,
  ): Promise<{ item: QuickMessage; version: number }> {
    return this.gateway(slot).addQuickMessage(draft);
  }

  updateQuickMessage(
    slot: string,
    id: number,
    draft: QuickMessageDraft,
  ): Promise<{ item: QuickMessage; version: number }> {
    return this.gateway(slot).updateQuickMessage(id, draft);
  }

  removeQuickMessages(
    slot: string,
    ids: number[],
  ): Promise<{ itemIds: number[]; version: number }> {
    return this.gateway(slot).removeQuickMessages(ids);
  }

  // ---- friend state (personal accounts) ----

  // Friend state lives at Zalo; every mutation invalidates the client's
  // contact cache exactly like a realtime friend_event does.
  private contactsChanged(slot: string) {
    this.tunnel.broadcastAccount(slot, "contacts.changed", {});
    this.tunnel.notifyManifestChanged();
  }

  private async contactAction(
    slot: string,
    action: (gw: ZaloGateway) => Promise<void>,
  ): Promise<void> {
    await action(this.gateway(slot));
    this.contactsChanged(slot);
  }

  sendFriendRequest(slot: string, uid: string, message: string) {
    return this.contactAction(slot, (gw) => gw.sendFriendRequest(uid, message));
  }

  acceptFriendRequest(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.acceptFriendRequest(uid));
  }

  rejectFriendRequest(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.rejectFriendRequest(uid));
  }

  cancelFriendRequest(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.undoFriendRequest(uid));
  }

  setFriendAlias(slot: string, uid: string, alias: string) {
    return this.contactAction(slot, (gw) => gw.setFriendAlias(uid, alias));
  }

  removeFriendAlias(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.removeFriendAlias(uid));
  }

  removeFriend(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.removeFriend(uid));
  }

  blockUser(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.blockUser(uid));
  }

  unblockUser(slot: string, uid: string) {
    return this.contactAction(slot, (gw) => gw.unblockUser(uid));
  }
}

// Upper bound of one on-demand group history fetch (messages).
const GROUP_HISTORY_MAX = 500;

// Label wire shape -> clear labels table row.
function labelRow(l: Label) {
  return {
    id: l.id,
    text: l.text,
    textKey: l.textKey,
    conversations: l.conversations,
    color: l.color,
    offset: l.offset,
    emoji: l.emoji,
    createTime: l.createTime,
  };
}

// Normalized display quote built from the quoted message's raw payload.
function normalizeQuote(raw: unknown): Message["quote"] | undefined {
  if (raw === null || typeof raw !== "object") return undefined;
  const r = raw as Record<string, unknown>;
  if (typeof r.msgId !== "string" && typeof r.msgId !== "number") {
    return undefined;
  }
  return {
    msgId: String(r.msgId),
    senderId: typeof r.uidFrom === "string" ? r.uidFrom : "",
    senderName: typeof r.dName === "string" ? r.dName : "",
    text: typeof r.content === "string" ? r.content : "",
  };
}

// The stored body_json is the wire record (clear fields + `body` or
// `sealed`). rowToRecord returns it as-is with recalled applied.
export function rowToRecord(row: {
  msg_id: string;
  cli_id: string | null;
  body_json: string;
  recalled: number;
}): Record<string, unknown> & { reactions: Record<string, string[]> } {
  const rec = JSON.parse(row.body_json) as Record<
    string,
    unknown
  > & { reactions: Record<string, string[]> };
  rec.id = row.msg_id;
  rec.cliId = row.cli_id;
  rec.recalled = !!row.recalled;
  return rec;
}

// Mutates rec.reactions. Returns false when nothing changed (dedupe).
export function applyReaction(
  rec: { reactions: Record<string, string[]> },
  icon: string,
  userId: string,
): boolean {
  if (icon === "") {
    let changed = false;
    for (const k of Object.keys(rec.reactions)) {
      const before = rec.reactions[k];
      const after = before.filter((u) => u !== userId);
      if (after.length !== before.length) {
        rec.reactions[k] = after;
        if (after.length === 0) delete rec.reactions[k];
        changed = true;
      }
    }
    return changed;
  }
  let changed = false;
  // Zalo keeps one reaction per user: changing the icon must remove the
  // user from every other icon first.
  for (const k of Object.keys(rec.reactions)) {
    if (k === icon) continue;
    const before = rec.reactions[k];
    const after = before.filter((u) => u !== userId);
    if (after.length !== before.length) {
      if (after.length === 0) delete rec.reactions[k];
      else rec.reactions[k] = after;
      changed = true;
    }
  }
  const users = new Set(rec.reactions[icon] ?? []);
  if (!users.has(userId)) {
    users.add(userId);
    rec.reactions[icon] = [...users];
    changed = true;
  }
  return changed;
}

// Echoes rebuild the body from the gateway payload and never carry the
// delivery state folded from receipts. Keep the existing state unless the
// echo itself has newer data (a higher state rank or a larger seenBy).
function mergeDelivery(prev: unknown, next: unknown): unknown {
  if (prev === undefined) return next;
  if (next === undefined) return prev;
  const rank: Record<string, number> = { sent: 0, delivered: 1, seen: 2 };
  const p = (prev ?? {}) as Record<string, unknown>;
  const n = (next ?? {}) as Record<string, unknown>;
  const pr = rank[String(p.state ?? "")] ?? 0;
  const nr = rank[String(n.state ?? "")] ?? 0;
  if (nr !== pr) return nr > pr ? n : p;
  return Number(n.seenBy ?? 0) > Number(p.seenBy ?? 0) ? n : p;
}

// Only the non-content fields the zca calls need (msgId, cliMsgId, uidFrom,
// idTo, msgType, ts, st, at, cmd, ttl) plus the forward reference metadata
// (logSrcType, fwLvl) stay clear in ref_json.
const REF_FIELDS = [
  "msgId",
  "cliMsgId",
  "uidFrom",
  "idTo",
  "msgType",
  "ts",
  "st",
  "at",
  "cmd",
  "ttl",
  "logSrcType",
  "fwLvl",
] as const;

function refJson(m: Message): string | null {
  const raw = m.raw as Record<string, unknown> | undefined;
  if (raw === undefined) return null;
  const ref: Record<string, unknown> = {};
  for (const k of REF_FIELDS) {
    if (raw[k] !== undefined) ref[k] = raw[k];
  }
  return JSON.stringify(ref);
}

function messageToRow(slot: string, m: Message) {
  return {
    slot,
    msgId: m.id,
    cliId: m.cliId,
    threadId: m.threadId,
    threadType: m.threadType,
    senderId: m.senderId,
    ts: m.ts,
    isSelf: m.isSelf,
    kind: m.kind,
    refJson: refJson(m),
    // The clear column drives the local TTL sweeper; the value is also in
    // the sealed body so clients can render a countdown.
    expiresAt:
      m.expiresAt ??
      (m.ttl !== undefined && m.ttl > 0 ? m.ts + m.ttl : 0),
  };
}
