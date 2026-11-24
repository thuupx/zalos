// SQLite store: schema plus every query the server uses.
import { Database } from "bun:sqlite";
import { mkdirSync, chmodSync } from "node:fs";
import { join } from "node:path";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const noise = require("../../vendor/zalos-noise/zalos_noise.js");
const vaultWasm = require("../../vendor/zalos-vault/zalos_vault.js");

export const EVENT_LOG_KEEP = 5000;

export type DeviceRow = {
  box_public_key: string;
  vault_requested_at: number | null;
  vault_wrapped: string | null;
  id: string;
  name: string;
  public_key: string;
  psk: string;
  role: "admin" | "member";
  created_at: number;
  last_seen_at: number | null;
  revoked_at: number | null;
};

export type PairingRow = {
  id: string;
  secret: string;
  role: "admin" | "member";
  expires_at: number;
  used_at: number | null;
};

export type ProfileKind = "user" | "group" | "full_avatar";

export type VaultState = "unsealed" | "migrating" | "sealed";

export type AccountRow = {
  slot: string;
  kind: "personal" | "oa";
  zalo_uid: string | null;
  display_name: string;
  avatar_url: string;
  credentials_json: string;
  vault_public_key: string | null;
  vault_state: VaultState;
  vault_key_version: number;
  status: string;
  created_at: number;
};

export type MessageRow = {
  slot: string;
  msg_id: string;
  cli_id: string | null;
  ref_json: string | null;
  thread_id: string;
  thread_type: string;
  sender_id: string;
  ts: number;
  is_self: number;
  kind: string;
  body_json: string;
  recalled: number;
  // Per-message self-destruct deadline (ms epoch); 0 is off. Independent
  // of the per-conversation auto_delete_ttl on threads.
  expires_at: number;
};

export type EventRow = {
  slot: string;
  seq: number;
  ts: number;
  type: string;
  data_json: string;
};

// Conversation labels are clear metadata (names and assignments), never
// sealed message content.
export type LabelRow = {
  id: number;
  text: string;
  textKey: string;
  conversations: string[];
  color: string;
  offset: number;
  emoji: string;
  createTime: number;
};

function randHex(bytes: number): string {
  const b = new Uint8Array(bytes);
  crypto.getRandomValues(b);
  return Buffer.from(b).toString("hex");
}

export function toHex(bytes: Uint8Array): string {
  return Buffer.from(bytes).toString("hex");
}

export function fromHex(hex: string): Uint8Array {
  return new Uint8Array(Buffer.from(hex, "hex"));
}

export function fingerprint(publicKeyHex: string): string {
  return vaultWasm.fingerprint(fromHex(publicKeyHex)) as string;
}

export class Store {
  readonly db: Database;
  readonly dir: string;

  constructor(dir: string) {
    this.dir = dir;
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    chmodSync(dir, 0o700);
    this.db = new Database(join(dir, "zalos.db"));
    this.db.exec("PRAGMA journal_mode = WAL");
    // Overwrite deleted and updated cells from the start, including session
    // credentials. Operations that require physical reclamation also vacuum
    // and checkpoint after their transaction commits.
    this.db.exec("PRAGMA secure_delete = ON");
    this.db.exec(`CREATE TABLE IF NOT EXISTS meta (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    )`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      public_key TEXT NOT NULL UNIQUE,
      psk TEXT NOT NULL,
      box_public_key TEXT NOT NULL DEFAULT '',
      vault_requested_at INTEGER,
      vault_wrapped TEXT,
      role TEXT NOT NULL CHECK (role IN ('admin','member')),
      created_at INTEGER NOT NULL,
      last_seen_at INTEGER,
      revoked_at INTEGER
    )`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS pairings (
      id TEXT PRIMARY KEY,
      secret TEXT NOT NULL,
      role TEXT NOT NULL,
      expires_at INTEGER NOT NULL,
      used_at INTEGER
    )`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS accounts (
      slot TEXT PRIMARY KEY,
      zalo_uid TEXT,
      display_name TEXT NOT NULL DEFAULT '',
      avatar_url TEXT NOT NULL DEFAULT '',
      credentials_json TEXT NOT NULL DEFAULT '',
      vault_public_key TEXT,
      status TEXT NOT NULL DEFAULT 'offline',
      created_at INTEGER NOT NULL
    )`);
    try {
      this.db.exec("ALTER TABLE accounts ADD COLUMN kind TEXT NOT NULL DEFAULT 'personal'");
    } catch {}
    try {
      this.db.exec("ALTER TABLE accounts ADD COLUMN vault_state TEXT NOT NULL DEFAULT 'unsealed'");
    } catch {}
    try {
      this.db.exec("ALTER TABLE accounts ADD COLUMN vault_key_version INTEGER NOT NULL DEFAULT 1");
    } catch {}
    // Existing accounts with a vault_public_key created before vault_state
    // existed are upgraded to 'migrating' so startup verifies their cache.
    this.db.exec(
      "UPDATE accounts SET vault_state = 'migrating' WHERE vault_public_key IS NOT NULL AND vault_state = 'unsealed'",
    );
    this.db.exec(`CREATE TABLE IF NOT EXISTS media_refs (
      slot TEXT NOT NULL,
      url_hash TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      thread_type TEXT NOT NULL,
      msg_id TEXT NOT NULL,
      PRIMARY KEY (slot, url_hash, msg_id)
    )`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_media_refs_msg
      ON media_refs (slot, msg_id)`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_media_refs_thread
      ON media_refs (slot, thread_id, thread_type)`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS idempotency_keys (
      slot TEXT NOT NULL,
      cli_id TEXT NOT NULL,
      method TEXT NOT NULL,
      request_hash TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('pending','completed','unknown')),
      result_json TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      PRIMARY KEY (slot, cli_id)
    )`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_idempotency_updated
      ON idempotency_keys (updated_at)`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS acl (
      device_id TEXT NOT NULL,
      slot TEXT NOT NULL,
      PRIMARY KEY (device_id, slot)
    )`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS threads (
      slot TEXT NOT NULL,
      thread_id TEXT NOT NULL,
      type TEXT NOT NULL,
      name TEXT NOT NULL DEFAULT '',
      avatar_url TEXT NOT NULL DEFAULT '',
      last_msg_id TEXT,
      last_ts INTEGER NOT NULL DEFAULT 0,
      unread INTEGER NOT NULL DEFAULT 0,
      pinned INTEGER NOT NULL DEFAULT 0,
      muted INTEGER NOT NULL DEFAULT 0,
      marked_unread INTEGER NOT NULL DEFAULT 0,
      hidden INTEGER NOT NULL DEFAULT 0,
      archived INTEGER NOT NULL DEFAULT 0,
      auto_delete_ttl INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (slot, thread_id, type)
    )`);
    // Migration for databases created before marked_unread existed.
    try {
      this.db.exec("ALTER TABLE threads ADD COLUMN marked_unread INTEGER NOT NULL DEFAULT 0");
    } catch {}
    // Phase D conversation state: hidden/archived flags and the
    // per-conversation auto-delete TTL (ms; 0 is off).
    try {
      this.db.exec("ALTER TABLE threads ADD COLUMN hidden INTEGER NOT NULL DEFAULT 0");
    } catch {}
    try {
      this.db.exec("ALTER TABLE threads ADD COLUMN archived INTEGER NOT NULL DEFAULT 0");
    } catch {}
    try {
      this.db.exec("ALTER TABLE threads ADD COLUMN auto_delete_ttl INTEGER NOT NULL DEFAULT 0");
    } catch {}
    this.db.exec(`CREATE TABLE IF NOT EXISTS messages (
      slot TEXT NOT NULL,
      msg_id TEXT NOT NULL,
      cli_id TEXT,
      ref_json TEXT,
      thread_id TEXT NOT NULL,
      thread_type TEXT NOT NULL,
      sender_id TEXT NOT NULL,
      ts INTEGER NOT NULL,
      is_self INTEGER NOT NULL DEFAULT 0,
      kind TEXT NOT NULL,
      body_json TEXT NOT NULL,
      recalled INTEGER NOT NULL DEFAULT 0,
      expires_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (slot, msg_id)
    )`);
    // Migration for databases created before per-message TTL existed.
    try {
      this.db.exec("ALTER TABLE messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0");
    } catch {}
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_messages_thread
      ON messages (slot, thread_id, thread_type, ts)`);
    this.db.exec(`CREATE INDEX IF NOT EXISTS idx_messages_expiry
      ON messages (slot, expires_at) WHERE expires_at > 0`);
    this.db.exec(`CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_cli
      ON messages (slot, cli_id) WHERE cli_id IS NOT NULL`);
      this.db.run(`CREATE TABLE IF NOT EXISTS profiles (
        slot TEXT,
        uid TEXT,
        kind TEXT,
        name TEXT,
        avatar_url TEXT,
        fetched_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (slot, uid, kind))`);
    try {
      this.db.exec("ALTER TABLE profiles ADD COLUMN fetched_at INTEGER NOT NULL DEFAULT 0");
    } catch {}
    // Conversation labels: clear metadata so labels can be listed offline
    // and assigned without sealing message content.
    this.db.exec(`CREATE TABLE IF NOT EXISTS labels (
      slot TEXT NOT NULL,
      label_id INTEGER NOT NULL,
      text TEXT NOT NULL,
      text_key TEXT NOT NULL DEFAULT '',
      conversations_json TEXT NOT NULL DEFAULT '[]',
      color TEXT NOT NULL DEFAULT '',
      offset INTEGER NOT NULL DEFAULT 0,
      emoji TEXT NOT NULL DEFAULT '',
      create_time INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (slot, label_id)
    )`);
    this.db.exec(`CREATE TABLE IF NOT EXISTS label_state (
      slot TEXT PRIMARY KEY,
      version INTEGER NOT NULL,
      last_update_time INTEGER NOT NULL
    )`);

    this.db.exec(`CREATE TABLE IF NOT EXISTS events (
      slot TEXT NOT NULL,
      seq INTEGER NOT NULL,
      ts INTEGER NOT NULL,
      type TEXT NOT NULL,
      data_json TEXT NOT NULL,
      PRIMARY KEY (slot, seq)
    )`);
    // Sequence numbers must never go backwards: pruning the log or
    // restarting the server must not reissue seq values a client already
    // saw, or it would silently drop the new events as already-seen.
    this.db.exec(`CREATE TABLE IF NOT EXISTS event_counters (
      slot TEXT PRIMARY KEY,
      seq INTEGER NOT NULL
    )`);
    this.db.exec(`INSERT INTO event_counters (slot, seq)
      SELECT slot, MAX(seq) FROM events GROUP BY slot
      ON CONFLICT(slot) DO NOTHING`);
    this.db
      .query(
        "INSERT INTO meta (key, value) VALUES ('vault_claimed', '0') ON CONFLICT(key) DO NOTHING",
      )
      .run();
    chmodSync(join(dir, "zalos.db"), 0o600);
  }

  // ---- server key ----

  serverKeypair(): { public: Uint8Array; private: Uint8Array } {
    const path = join(this.dir, "server.key");
    let hex = this.getMeta("server_key");
    if (hex === null) {
      const kp = noise.generate_keypair();
      const json = JSON.stringify({
        public: toHex(kp.public),
        private: toHex(kp.private),
      });
      Bun.write(path, json);
      chmodSync(path, 0o600);
      this.setMeta("server_key", json);
      hex = json;
    }
    const kp = JSON.parse(hex);
    return { public: fromHex(kp.public), private: fromHex(kp.private) };
  }

  getMeta(key: string): string | null {
    const row = this.db
      .query("SELECT value FROM meta WHERE key = ?")
      .get(key) as { value: string } | null;
    return row?.value ?? null;
  }

  setMeta(key: string, value: string) {
    this.db
      .query("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
      .run(key, value);
  }

  // Flush the WAL into the main file and truncate it. Call after any
  // operation that must leave no plaintext (or stale key material) in
  // zalos.db-wal, e.g. vault sealing, vault reset, content scrubbing.
  checkpoint() {
    this.db.exec("PRAGMA wal_checkpoint(TRUNCATE)");
  }

  reclaimDeletedData() {
    this.db.exec("PRAGMA secure_delete = ON");
    this.db.exec("VACUUM");
    this.checkpoint();
  }

  // Strip `body`/`sealed` content of messages from earlier event log
  // entries. Entries stay in place so seq has no gaps. Accepts a set so a
  // bulk expiry sweep scans the log once.
  scrubMessageEvents(slot: string, msgIds: string | Set<string>) {
    const ids = typeof msgIds === "string" ? new Set([msgIds]) : msgIds;
    if (ids.size === 0) return;
    const scrub = (v: unknown): boolean => {
      let changed = false;
      if (v === null || typeof v !== "object") return false;
      if (Array.isArray(v)) {
        for (const item of v) changed = scrub(item) || changed;
        return changed;
      }
      const o = v as Record<string, unknown>;
      if (
        typeof o.id === "string" &&
        ids.has(o.id) &&
        (o.body !== undefined || o.sealed !== undefined)
      ) {
        delete o.body;
        delete o.sealed;
        changed = true;
      }
      for (const item of Object.values(o)) changed = scrub(item) || changed;
      return changed;
    };
    for (const ev of this.allEventRows(slot)) {
      const data = JSON.parse(ev.data_json) as unknown;
      if (scrub(data)) this.updateEventData(slot, ev.seq, JSON.stringify(data));
    }
  }

  // messages.delete for me: row gone, content gone from the event log.
  deleteMessage(slot: string, msgId: string) {
    const tx = this.db.transaction(() => {
      this.db
        .query("DELETE FROM messages WHERE slot = ? AND msg_id = ?")
        .run(slot, msgId);
      this.scrubMessageEvents(slot, msgId);
    });
    tx();
  }

  // Bulk variant for the auto-delete sweeper: one event-log scan for the
  // whole batch.
  deleteMessages(slot: string, msgIds: string[]) {
    if (msgIds.length === 0) return;
    const tx = this.db.transaction(() => {
      const del = this.db.query(
        "DELETE FROM messages WHERE slot = ? AND msg_id = ?",
      );
      for (const msgId of msgIds) del.run(slot, msgId);
      this.scrubMessageEvents(slot, new Set(msgIds));
    });
    tx();
  }

  // ---- devices ----

  createDevice(d: {
    name: string;
    publicKey: string;
    psk: string;
    boxPublicKey?: string;
    role: "admin" | "member";
  }): DeviceRow {
    const id = randHex(8);
    this.db
      .query(
        `INSERT INTO devices (id, name, public_key, psk, box_public_key, role, created_at)
         VALUES (?, ?, ?, ?, ?, ?, ?)`,
      )
      .run(id, d.name, d.publicKey, d.psk, d.boxPublicKey ?? "", d.role, Date.now());
    return this.deviceById(id)!;
  }

  adminCount(): number {
    return (
      this.db
        .query(
          "SELECT count(*) n FROM devices WHERE role = 'admin' AND revoked_at IS NULL",
        )
        .get() as { n: number }
    ).n;
  }

  deviceCount(): number {
    return (this.db.query("SELECT count(*) n FROM devices").get() as { n: number })
      .n;
  }

  deviceById(id: string): DeviceRow | null {
    return (this.db.query("SELECT * FROM devices WHERE id = ?").get(id) ??
      null) as DeviceRow | null;
  }

  deviceByPublicKey(publicKey: string): DeviceRow | null {
    return (this.db
      .query("SELECT * FROM devices WHERE public_key = ?")
      .get(publicKey) ?? null) as DeviceRow | null;
  }

  listDevices(includeRevoked = false): DeviceRow[] {
    return this.db
      .query(
        `SELECT * FROM devices ${includeRevoked ? "" : "WHERE revoked_at IS NULL"}
         ORDER BY created_at`,
      )
      .all() as DeviceRow[];
  }

  revokeDevice(id: string) {
    // Tombstone: the row stays (id + revoked_at) but the Noise public key
    // and psk are wiped, so nothing on disk can authenticate as the device.
    // Re-pairing the same key then creates a fresh device whose ACL follows
    // the new role: all accounts for an admin, none implicit for a member.
    // secure_delete zeroes the overwritten cells; VACUUM then rebuilds the
    // file so no freed page still holds the old psk/public key bytes.
    this.db.exec("PRAGMA secure_delete=ON");
    this.db
      .query(
        `UPDATE devices SET revoked_at = ?, public_key = ?, psk = '',
         vault_requested_at = NULL, vault_wrapped = NULL,
         box_public_key = '' WHERE id = ?`,
      )
      .run(Date.now(), `revoked:${id}:${Date.now()}`, id);
    this.db.query("DELETE FROM acl WHERE device_id = ?").run(id);
    this.db.exec("VACUUM");
    this.checkpoint();
  }

  // `zalos vault reset`: the root holder lost the root. Drop every sealed
  // record's content (unreadable anyway), clear keys, claims and requests.
  vaultReset() {
    const dropSealed = (v: unknown) => {
      if (v === null || typeof v !== "object") return;
      if (Array.isArray(v)) {
        for (const item of v) dropSealed(item);
        return;
      }
      const o = v as Record<string, unknown>;
      delete o.sealed;
      for (const item of Object.values(o)) dropSealed(item);
    };
    const tx = this.db.transaction(() => {
      this.db
        .query("UPDATE meta SET value = '0' WHERE key = 'vault_claimed'")
        .run();
      this.db
        .query("UPDATE accounts SET vault_public_key = NULL, vault_state = 'unsealed', vault_key_version = 1")
        .run();
      this.db
        .query(
          "UPDATE devices SET vault_requested_at = NULL, vault_wrapped = NULL",
        )
        .run();
      for (const row of this.db
        .query("SELECT slot, msg_id, body_json FROM messages")
        .all() as { slot: string; msg_id: string; body_json: string }[]) {
        const rec = JSON.parse(row.body_json) as Record<string, unknown>;
        if (rec.sealed === undefined) continue;
        delete rec.sealed;
        this.db
          .query(
            "UPDATE messages SET body_json = ? WHERE slot = ? AND msg_id = ?",
          )
          .run(JSON.stringify(rec), row.slot, row.msg_id);
      }
      for (const row of this.db
        .query("SELECT slot, seq, data_json FROM events")
        .all() as { slot: string; seq: number; data_json: string }[]) {
        const before = row.data_json;
        const data = JSON.parse(row.data_json) as unknown;
        dropSealed(data);
        const after = JSON.stringify(data);
        if (after !== before) {
          this.db
            .query(
              "UPDATE events SET data_json = ? WHERE slot = ? AND seq = ?",
            )
            .run(after, row.slot, row.seq);
        }
      }
    });
    tx();
    this.db.exec("PRAGMA secure_delete=ON");
    this.db.exec("VACUUM");
    this.checkpoint();
  }

  setVaultRequest(deviceId: string) {
    this.db
      .query("UPDATE devices SET vault_requested_at = ? WHERE id = ?")
      .run(Date.now(), deviceId);
  }

  vaultRequesters(): DeviceRow[] {
    return this.db
      .query(
        `SELECT * FROM devices
         WHERE vault_requested_at IS NOT NULL AND revoked_at IS NULL`,
      )
      .all() as DeviceRow[];
  }

  grantVault(deviceId: string, wrapped: string) {
    this.db
      .query(
        `UPDATE devices SET vault_wrapped = ?, vault_requested_at = NULL
         WHERE id = ?`,
      )
      .run(wrapped, deviceId);
  }

  rejectVault(deviceId: string) {
    this.db
      .query(
        `UPDATE devices SET vault_requested_at = NULL WHERE id = ?`,
      )
      .run(deviceId);
  }

  vaultWrapped(deviceId: string): string | null {
    const row = this.db
      .query("SELECT vault_wrapped FROM devices WHERE id = ?")
      .get(deviceId) as { vault_wrapped: string | null } | null;
    return row?.vault_wrapped ?? null;
  }

  // Atomic compare-and-set: true only for the first caller ever.
  claimVault(): boolean {
    const row = this.db
      .query(
        `UPDATE meta SET value = '1'
         WHERE key = 'vault_claimed' AND value = '0'`,
      )
      .run();
    return row.changes === 1;
  }

  clearVaultWrapped(deviceId: string) {
    this.db
      .query("UPDATE devices SET vault_wrapped = NULL WHERE id = ?")
      .run(deviceId);
  }

  touchDevice(id: string) {
    this.db
      .query("UPDATE devices SET last_seen_at = ? WHERE id = ?")
      .run(Date.now(), id);
  }

  deviceAcl(deviceId: string): string[] {
    return (
      this.db
        .query("SELECT slot FROM acl WHERE device_id = ?")
        .all(deviceId) as { slot: string }[]
    ).map((r) => r.slot);
  }

  setAcl(deviceId: string, slots: string[]) {
    this.db.query("DELETE FROM acl WHERE device_id = ?").run(deviceId);
    const ins = this.db.query(
      "INSERT OR IGNORE INTO acl (device_id, slot) VALUES (?, ?)",
    );
    for (const slot of slots) ins.run(deviceId, slot);
  }

  hasAcl(deviceId: string, slot: string): boolean {
    return (
      this.db
        .query("SELECT 1 x FROM acl WHERE device_id = ? AND slot = ?")
        .get(deviceId, slot) !== null
    );
  }

  // ---- pairings ----

  createPairing(role: "admin" | "member", ttlMs = 10 * 60 * 1000): PairingRow {
    const id = randHex(8);
    const secret = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("hex");
    this.db
      .query(
        "INSERT INTO pairings (id, secret, role, expires_at) VALUES (?, ?, ?, ?)",
      )
      .run(id, secret, role, Date.now() + ttlMs);
    return this.pairingById(id)!;
  }

  pairingById(id: string): PairingRow | null {
    return (this.db.query("SELECT * FROM pairings WHERE id = ?").get(id) ??
      null) as PairingRow | null;
  }

  consumePairing(id: string) {
    this.db
      .query("UPDATE pairings SET used_at = ? WHERE id = ?")
      .run(Date.now(), id);
  }

  // Atomically consume a pairing and create-or-replace the device for
  // `publicKey`. Returns null when the pairing is already consumed.
  completePairing(opts: {
    pairingId: string;
    role: "admin" | "member";
    publicKey: string;
    psk: string;
    name: string;
    boxPublicKey?: string;
  }): DeviceRow | null {
    const tx = this.db.transaction(() => {
      const consumed = this.db
        .query(
          "UPDATE pairings SET used_at = ? WHERE id = ? AND used_at IS NULL",
        )
        .run(Date.now(), opts.pairingId);
      if (consumed.changes === 0) return null;

      const existing = this.deviceByPublicKey(opts.publicKey);
      if (existing !== null) {
        // Re-pairing a live key (same device still holds it): new psk,
        // pairing role, same id; the ACL is preserved. A revoked device's
        // key was tombstoned, so it does not reach this branch and gets a
        // fresh device whose ACL follows its new role below.
        this.db
          .query(
            `UPDATE devices SET psk = ?, role = ?, revoked_at = NULL,
             name = ?, box_public_key = ? WHERE id = ?`,
          )
          .run(opts.psk, opts.role, opts.name, opts.boxPublicKey ?? "", existing.id);
        return this.deviceById(existing.id)!;
      }
      const role = this.deviceCount() === 0 ? "admin" : opts.role;
      const id = randHex(8);
      this.db
        .query(
          `INSERT INTO devices (id, name, public_key, psk, box_public_key, role, created_at)
           VALUES (?, ?, ?, ?, ?, ?, ?)`,
        )
        .run(id, opts.name, opts.publicKey, opts.psk, opts.boxPublicKey ?? "", role, Date.now());
      const device = this.deviceById(id)!;
      // Administrators retain the existing all-account behavior. Members
      // start with no implicit access and require explicit ACL grants.
      this.setAcl(
        device.id,
        role === "admin" ? this.listAccounts().map((a) => a.slot) : [],
      );
      return device;
    });
    return tx();
  }

  // ---- accounts ----

  createAccount(a: {
    kind?: "personal" | "oa";
    zaloUid: string | null;
    displayName: string;
    avatarUrl: string;
    credentialsJson: string;
  }): AccountRow {
    const tx = this.db.transaction(() => {
      let slot: string;
      do {
        slot = randHex(6);
      } while (this.accountBySlot(slot) !== null);
      this.db
        .query(
          `INSERT INTO accounts (slot, kind, zalo_uid, display_name, avatar_url, credentials_json, status, created_at)
           VALUES (?, ?, ?, ?, ?, ?, 'starting', ?)`,
        )
        .run(
          slot,
          a.kind ?? "personal",
          a.zaloUid,
          a.displayName,
          a.avatarUrl,
          a.credentialsJson,
          Date.now(),
        );
      // Every account-creation path, including the CLI, grants the new slot
      // only to current administrators. Member grants remain explicit.
      const grant = this.db.query(
        "INSERT OR IGNORE INTO acl (device_id, slot) VALUES (?, ?)",
      );
      for (const device of this.listDevices()) {
        if (device.role === "admin") grant.run(device.id, slot);
      }
      return this.accountBySlot(slot)!;
    });
    return tx();
  }

  accountBySlot(slot: string): AccountRow | null {
    return (this.db.query("SELECT * FROM accounts WHERE slot = ?").get(slot) ??
      null) as AccountRow | null;
  }

  listAccounts(): AccountRow[] {
    return this.db
      .query("SELECT * FROM accounts ORDER BY created_at")
      .all() as AccountRow[];
  }

  setVaultKey(slot: string, publicKey: string, state: VaultState = "migrating") {
    this.db
      .query("UPDATE accounts SET vault_public_key = ?, vault_state = ? WHERE slot = ?")
      .run(publicKey, state, slot);
  }

  setVaultState(slot: string, state: VaultState) {
    this.db
      .query("UPDATE accounts SET vault_state = ? WHERE slot = ?")
      .run(state, slot);
  }

  rotateVaultKey(
    slot: string,
    expectedVersion: number,
    newPublicKey: string,
  ): number | null {
    const nextVersion = expectedVersion + 1;
    const res = this.db
      .query(
        `UPDATE accounts
         SET vault_public_key = ?, vault_key_version = ?, vault_state = 'sealed'
         WHERE slot = ? AND vault_public_key IS NOT NULL AND vault_key_version = ?`,
      )
      .run(newPublicKey, nextVersion, slot, expectedVersion);
    return res.changes > 0 ? nextVersion : null;
  }

  recordMediaRefs(
    slot: string,
    threadId: string,
    threadType: string,
    msgId: string,
    urlHashes: string[],
  ) {
    if (urlHashes.length === 0) return;
    const q = this.db.query(
      `INSERT OR IGNORE INTO media_refs (slot, url_hash, thread_id, thread_type, msg_id)
       VALUES (?, ?, ?, ?, ?)`,
    );
    for (const h of urlHashes) {
      if (h !== "") q.run(slot, h, threadId, threadType, msgId);
    }
  }

  // Removes ownership entries for the given messages and returns the url_hashes
  // that now have zero remaining references for this account.
  releaseMediaRefsForMessages(slot: string, msgIds: string[]): string[] {
    if (msgIds.length === 0) return [];
    const candidates = new Set<string>();
    const selectQ = this.db.query(
      "SELECT url_hash FROM media_refs WHERE slot = ? AND msg_id = ?",
    );
    const deleteQ = this.db.query(
      "DELETE FROM media_refs WHERE slot = ? AND msg_id = ?",
    );
    for (const id of msgIds) {
      for (const r of selectQ.all(slot, id) as { url_hash: string }[]) {
        candidates.add(r.url_hash);
      }
      deleteQ.run(slot, id);
    }
    return this.unreferencedMediaHashes(slot, candidates);
  }

  releaseMediaRefsForThread(
    slot: string,
    threadId: string,
    threadType: string,
  ): string[] {
    const rows = this.db
      .query(
        `SELECT DISTINCT url_hash FROM media_refs
         WHERE slot = ? AND thread_id = ? AND thread_type = ?`,
      )
      .all(slot, threadId, threadType) as { url_hash: string }[];
    this.db
      .query(
        `DELETE FROM media_refs
         WHERE slot = ? AND thread_id = ? AND thread_type = ?`,
      )
      .run(slot, threadId, threadType);
    return this.unreferencedMediaHashes(
      slot,
      new Set(rows.map((r) => r.url_hash)),
    );
  }

  private unreferencedMediaHashes(
    slot: string,
    candidates: Set<string>,
  ): string[] {
    if (candidates.size === 0) return [];
    const checkQ = this.db.query(
      "SELECT 1 FROM media_refs WHERE slot = ? AND url_hash = ? LIMIT 1",
    );
    const orphan: string[] = [];
    for (const h of candidates) {
      if (checkQ.get(slot, h) === null) orphan.push(h);
    }
    return orphan;
  }

  // ---- durable idempotency ----

  getIdempotencyKey(
    slot: string,
    cliId: string,
  ): {
    slot: string;
    cli_id: string;
    method: string;
    request_hash: string;
    state: "pending" | "completed" | "unknown";
    result_json: string | null;
    created_at: number;
    updated_at: number;
  } | null {
    return (this.db
      .query(
        "SELECT * FROM idempotency_keys WHERE slot = ? AND cli_id = ?",
      )
      .get(slot, cliId) ?? null) as {
      slot: string;
      cli_id: string;
      method: string;
      request_hash: string;
      state: "pending" | "completed" | "unknown";
      result_json: string | null;
      created_at: number;
      updated_at: number;
    } | null;
  }

  beginIdempotencyKey(
    slot: string,
    cliId: string,
    method: string,
    requestHash: string,
  ) {
    const now = Date.now();
    this.db
      .query(
        `INSERT INTO idempotency_keys (slot, cli_id, method, request_hash, state, result_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, 'pending', NULL, ?, ?)
         ON CONFLICT(slot, cli_id) DO UPDATE SET
           state = 'pending',
           updated_at = excluded.updated_at`,
      )
      .run(slot, cliId, method, requestHash, now, now);
  }

  completeIdempotencyKey(
    slot: string,
    cliId: string,
    result: { msgId: string; cliId: string },
  ) {
    this.db
      .query(
        `UPDATE idempotency_keys
         SET state = 'completed', result_json = ?, updated_at = ?
         WHERE slot = ? AND cli_id = ?`,
      )
      .run(JSON.stringify(result), Date.now(), slot, cliId);
  }

  deleteIdempotencyKey(slot: string, cliId: string) {
    this.db
      .query("DELETE FROM idempotency_keys WHERE slot = ? AND cli_id = ?")
      .run(slot, cliId);
  }

  pruneIdempotencyKeys(maxAgeMs = 24 * 60 * 60 * 1000) {
    this.db
      .query("DELETE FROM idempotency_keys WHERE updated_at < ?")
      .run(Date.now() - maxAgeMs);
  }

  updateAccountCredentials(slot: string, credentialsJson: string) {
    this.db
      .query("UPDATE accounts SET credentials_json = ? WHERE slot = ?")
      .run(credentialsJson, slot);
  }

  updateAccountStatus(slot: string, status: string) {
    this.db
      .query("UPDATE accounts SET status = ? WHERE slot = ?")
      .run(status, slot);
  }

  updateAccountProfile(slot: string, displayName: string, avatarUrl: string) {
    this.db
      .query(
        "UPDATE accounts SET display_name = ?, avatar_url = ? WHERE slot = ?",
      )
      .run(displayName, avatarUrl, slot);
  }

  updateAccountIdentity(
    slot: string,
    zaloUid: string,
    displayName: string,
    avatarUrl: string,
  ) {
    this.db
      .query(
        `UPDATE accounts SET zalo_uid = ?, display_name = ?, avatar_url = ?
         WHERE slot = ?`,
      )
      .run(zaloUid, displayName, avatarUrl, slot);
  }

  removeAccount(slot: string) {
    const tx = this.db.transaction(() => {
      for (const t of [
        "acl",
        "threads",
        "messages",
        "media_refs",
        "idempotency_keys",
        "events",
        "event_counters",
        "profiles",
        "labels",
        "label_state",
      ]) {
        this.db.query(`DELETE FROM ${t} WHERE slot = ?`).run(slot);
      }
      this.db.query("DELETE FROM accounts WHERE slot = ?").run(slot);
    });
    tx();
    this.reclaimDeletedData();
  }

  unreadForSlot(slot: string): number {
    const row = this.db
      .query("SELECT COALESCE(SUM(unread),0) n FROM threads WHERE slot = ?")
      .get(slot) as { n: number };
    return row.n;
  }

  // ---- threads ----

  upsertThread(t: {
    slot: string;
    threadId: string;
    type: string;
    name?: string;
    avatarUrl?: string;
  }) {
    this.db
      .query(
        `INSERT INTO threads (slot, thread_id, type, name, avatar_url)
         VALUES (?, ?, ?, ?, ?)
         ON CONFLICT(slot, thread_id, type) DO NOTHING`,
      )
      .run(t.slot, t.threadId, t.type, t.name ?? "", t.avatarUrl ?? "");
  }

  updateThreadLast(slot: string, threadId: string, type: string, msgId: string, ts: number) {
    this.db
      .query(
        `UPDATE threads SET last_msg_id = ?, last_ts = ?
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(msgId, ts, slot, threadId, type);
  }

  bumpUnread(slot: string, threadId: string, type: string, delta: number) {
    this.db
      .query(
        `UPDATE threads SET unread = MAX(0, unread + ?)
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(delta, slot, threadId, type);
  }

  clearUnread(slot: string, threadId: string, type: string) {
    this.db
      .query(
        `UPDATE threads SET unread = 0
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(slot, threadId, type);
  }

  setThreadFlag(
    slot: string,
    threadId: string,
    type: string,
    flag: "pinned" | "muted" | "marked_unread" | "hidden" | "archived",
    value: boolean,
  ) {
    this.db
      .query(
        `UPDATE threads SET ${flag} = ?
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(value ? 1 : 0, slot, threadId, type);
  }

  // Per-conversation auto-delete TTL in ms; 0 is off.
  setThreadTtl(slot: string, threadId: string, type: string, ttl: number) {
    this.db
      .query(
        `UPDATE threads SET auto_delete_ttl = ?
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(ttl, slot, threadId, type);
  }

  // Mark unread keeps the conversation badge visible: unread >= 1 and the
  // marked_unread flag so markSeen can tell Zalo to remove the mark.
  markUnread(slot: string, threadId: string, type: string) {
    this.db
      .query(
        `UPDATE threads SET unread = MAX(1, unread), marked_unread = 1
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(slot, threadId, type);
  }

  // threads.delete: the thread, its messages and the messages' event-log
  // content are all removed locally; media cache files are deleted by the
  // caller (it owns the fs path).
  deleteThread(slot: string, threadId: string, type: string) {
    const tx = this.db.transaction(() => {
      const msgs = this.db
        .query(
          "SELECT msg_id FROM messages WHERE slot = ? AND thread_id = ? AND thread_type = ?",
        )
        .all(slot, threadId, type) as { msg_id: string }[];
      for (const m of msgs) this.scrubMessageEvents(slot, m.msg_id);
      this.db
        .query(
          "DELETE FROM messages WHERE slot = ? AND thread_id = ? AND thread_type = ?",
        )
        .run(slot, threadId, type);
      this.db
        .query(
          "DELETE FROM threads WHERE slot = ? AND thread_id = ? AND type = ?",
        )
        .run(slot, threadId, type);
    });
    tx();
  }

  updateThreadProfile(slot: string, threadId: string, type: string, name: string, avatarUrl: string) {
    this.db
      .query(
        `UPDATE threads SET name = ?, avatar_url = ?
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(name, avatarUrl, slot, threadId, type);
  }

  getThread(slot: string, threadId: string, type: string) {
    return this.db
      .query(
        "SELECT * FROM threads WHERE slot = ? AND thread_id = ? AND type = ?",
      )
      .get(slot, threadId, type) as Record<string, unknown> | null;
  }

  listThreads(slot: string, limit = 2000) {
    return this.db
      .query(
        `SELECT * FROM threads WHERE slot = ?
         ORDER BY pinned DESC, last_ts DESC LIMIT ?`,
      )
      .all(slot, limit) as Record<string, unknown>[];
  }

  // After deleting messages (auto-delete sweep) point the thread at its
  // newest remaining message, or clear it when the thread is empty.
  refreshThreadLast(slot: string, threadId: string, type: string) {
    const row = this.db
      .query(
        `SELECT msg_id, ts FROM messages
         WHERE slot = ? AND thread_id = ? AND thread_type = ?
         ORDER BY ts DESC, msg_id DESC LIMIT 1`,
      )
      .get(slot, threadId, type) as { msg_id: string; ts: number } | null;
    this.db
      .query(
        `UPDATE threads SET last_msg_id = ?, last_ts = ?
         WHERE slot = ? AND thread_id = ? AND type = ?`,
      )
      .run(row?.msg_id ?? null, row?.ts ?? 0, slot, threadId, type);
  }

  // Messages past their conversation's auto-delete TTL. TTL 0 means off.
  expiredMessages(slot: string, now: number): MessageRow[] {
    return this.db
      .query(
        `SELECT m.* FROM messages m
         JOIN threads t
           ON t.slot = m.slot AND t.thread_id = m.thread_id
          AND t.type = m.thread_type
         WHERE m.slot = ? AND t.auto_delete_ttl > 0
           AND m.ts < ? - t.auto_delete_ttl
         ORDER BY m.ts`,
      )
      .all(slot, now) as MessageRow[];
  }

  // Messages whose own self-destruct deadline passed. Separate from the
  // conversation auto-delete sweep above.
  expiredTtlMessages(slot: string, now: number): MessageRow[] {
    return this.db
      .query(
        `SELECT * FROM messages
         WHERE slot = ? AND expires_at > 0 AND expires_at <= ?
         ORDER BY expires_at`,
      )
      .all(slot, now) as MessageRow[];
  }

  // ---- messages ----

  upsertMessage(m: {
    slot: string;
    msgId: string;
    cliId: string | null;
    threadId: string;
    threadType: string;
    senderId: string;
    ts: number;
    isSelf: boolean;
    kind: string;
    bodyJson: string;
    refJson?: string | null;
    expiresAt?: number;
  }) {
    this.db
      .query(
        `INSERT INTO messages (slot, msg_id, cli_id, thread_id, thread_type, sender_id, ts, is_self, kind, body_json, recalled, ref_json, expires_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?)
         ON CONFLICT(slot, msg_id) DO UPDATE SET
           body_json = excluded.body_json,
           ref_json = excluded.ref_json,
           expires_at = MAX(expires_at, excluded.expires_at)`,
      )
      .run(
        m.slot,
        m.msgId,
        m.cliId,
        m.threadId,
        m.threadType,
        m.senderId,
        m.ts,
        m.isSelf ? 1 : 0,
        m.kind,
        m.bodyJson,
        m.refJson ?? null,
        m.expiresAt !== undefined && m.expiresAt > 0 ? m.expiresAt : 0,
      );
  }

  // Latest incoming message of a thread (for markSeen with original fields).
  latestIncomingRef(slot: string, threadId: string): unknown {
    const row = this.db
      .query(
        `SELECT ref_json FROM messages
         WHERE slot = ? AND thread_id = ? AND is_self = 0 AND ref_json IS NOT NULL
         ORDER BY ts DESC LIMIT 1`,
      )
      .get(slot, threadId) as { ref_json: string } | null;
    return row === null ? undefined : JSON.parse(row.ref_json);
  }

  messageRef(slot: string, msgId: string): unknown {
    const row = this.db
      .query("SELECT ref_json FROM messages WHERE slot = ? AND msg_id = ?")
      .get(slot, msgId) as { ref_json: string | null } | null;
    return row?.ref_json == null ? undefined : JSON.parse(row.ref_json);
  }

  allMessageRows(slot: string): MessageRow[] {
    return this.db
      .query("SELECT * FROM messages WHERE slot = ?")
      .all(slot) as MessageRow[];
  }

  allEventRows(slot: string) {
    return this.db
      .query("SELECT seq, data_json FROM events WHERE slot = ?")
      .all(slot) as { seq: number; data_json: string }[];
  }

  updateEventData(slot: string, seq: number, dataJson: string) {
    this.db
      .query("UPDATE events SET data_json = ? WHERE slot = ? AND seq = ?")
      .run(dataJson, slot, seq);
  }

  // "full_avatar" rows cache users.avatar: avatar_url is the full-size url.
  upsertProfile(p: {
    slot: string;
    uid: string;
    kind: ProfileKind;
    name: string;
    avatarUrl: string;
    fetchedAt?: number;
  }) {
    this.db
      .query(
        `INSERT INTO profiles (slot, uid, kind, name, avatar_url, fetched_at)
         VALUES (?, ?, ?, ?, ?, ?)
         ON CONFLICT(slot, uid, kind) DO UPDATE SET
           name = excluded.name, avatar_url = excluded.avatar_url,
           fetched_at = excluded.fetched_at`,
      )
      .run(p.slot, p.uid, p.kind, p.name, p.avatarUrl, p.fetchedAt ?? Date.now());
  }

  getProfile(
    slot: string,
    uid: string,
    kind: ProfileKind,
  ): { name: string; avatar_url: string } | null {
    return (this.db
      .query(
        "SELECT name, avatar_url FROM profiles WHERE slot = ? AND uid = ? AND kind = ?",
      )
      .get(slot, uid, kind) ?? null) as {
      name: string;
      avatar_url: string;
    } | null;
  }

  // 24 h cache lookup used by users.get; returns null when missing or stale.
  getProfileFresh(
    slot: string,
    uid: string,
    kind: ProfileKind,
    maxAgeMs: number,
  ): { name: string; avatar_url: string } | null {
    return (this.db
      .query(
        `SELECT name, avatar_url FROM profiles
         WHERE slot = ? AND uid = ? AND kind = ? AND fetched_at > ?`,
      )
      .get(slot, uid, kind, Date.now() - maxAgeMs) ?? null) as {
      name: string;
      avatar_url: string;
    } | null;
  }

  // ---- labels ----

  // Whole-set replacement in one transaction; labels are clear metadata.
  replaceLabels(
    slot: string,
    labels: LabelRow[],
    version: number,
    lastUpdateTime: number,
  ) {
    const tx = this.db.transaction(() => {
      this.db.query("DELETE FROM labels WHERE slot = ?").run(slot);
      const ins = this.db.query(
        `INSERT INTO labels
           (slot, label_id, text, text_key, conversations_json, color, offset, emoji, create_time)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      );
      for (const l of labels) {
        ins.run(
          slot,
          l.id,
          l.text,
          l.textKey,
          JSON.stringify(l.conversations),
          l.color,
          l.offset,
          l.emoji,
          l.createTime,
        );
      }
      this.db
        .query(
          `INSERT INTO label_state (slot, version, last_update_time)
           VALUES (?, ?, ?)
           ON CONFLICT(slot) DO UPDATE SET
             version = excluded.version,
             last_update_time = excluded.last_update_time`,
        )
        .run(slot, version, lastUpdateTime);
    });
    tx();
  }

  listLabels(slot: string): LabelRow[] {
    const rows = this.db
      .query(
        `SELECT * FROM labels WHERE slot = ?
         ORDER BY offset, label_id`,
      )
      .all(slot) as {
      label_id: number;
      text: string;
      text_key: string;
      conversations_json: string;
      color: string;
      offset: number;
      emoji: string;
      create_time: number;
    }[];
    return rows.map((r) => {
      let conversations: string[] = [];
      try {
        const parsed = JSON.parse(r.conversations_json) as unknown;
        if (Array.isArray(parsed)) {
          conversations = parsed.filter(
            (c): c is string => typeof c === "string" && c !== "",
          );
        }
      } catch {}
      return {
        id: r.label_id,
        text: r.text,
        textKey: r.text_key,
        conversations,
        color: r.color,
        offset: r.offset,
        emoji: r.emoji,
        createTime: r.create_time,
      };
    });
  }

  labelState(slot: string): { version: number; lastUpdateTime: number } | null {
    const row = this.db
      .query(
        "SELECT version, last_update_time FROM label_state WHERE slot = ?",
      )
      .get(slot) as { version: number; last_update_time: number } | null;
    return row === null
      ? null
      : { version: row.version, lastUpdateTime: row.last_update_time };
  }

  updateMessageBody(slot: string, msgId: string, bodyJson: string) {
    this.db
      .query("UPDATE messages SET body_json = ? WHERE slot = ? AND msg_id = ?")
      .run(bodyJson, slot, msgId);
  }

  markRecalled(slot: string, msgId: string) {
    this.db
      .query("UPDATE messages SET recalled = 1 WHERE slot = ? AND msg_id = ?")
      .run(slot, msgId);
  }

  getMessage(slot: string, msgId: string): MessageRow | null {
    return (this.db
      .query("SELECT * FROM messages WHERE slot = ? AND msg_id = ?")
      .get(slot, msgId) ?? null) as MessageRow | null;
  }

  getMessageByCliId(slot: string, cliId: string): MessageRow | null {
    return (this.db
      .query("SELECT * FROM messages WHERE slot = ? AND cli_id = ?")
      .get(slot, cliId) ?? null) as MessageRow | null;
  }

  listMessages(
    slot: string,
    threadId: string,
    threadType: string,
    limit: number,
    before?: { ts: number; id: string },
  ): MessageRow[] {
    // Newest-first page; `before` is an exclusive (ts, msg_id) cursor.
    const rows = this.db
      .query(
        `SELECT * FROM messages
         WHERE slot = ? AND thread_id = ? AND thread_type = ?
         ${before !== undefined ? "AND (ts < ? OR (ts = ? AND msg_id < ?))" : ""}
         ORDER BY ts DESC, msg_id DESC LIMIT ?`,
      )
      .all(
        ...(before !== undefined
          ? [slot, threadId, threadType, before.ts, before.ts, before.id, limit]
          : [slot, threadId, threadType, limit]),
      ) as MessageRow[];
    return rows;
  }

  countMessages(slot: string, threadId: string, threadType: string): number {
    const row = this.db
      .query(
        `SELECT COUNT(*) n FROM messages
         WHERE slot = ? AND thread_id = ? AND thread_type = ?`,
      )
      .get(slot, threadId, threadType) as { n: number };
    return row.n;
  }

  // ---- events ----

  appendEvent(slot: string, type: string, data: unknown): EventRow {
    const tx = this.db.transaction(() => {
      const seq = (
        this.db
          .query(
            "INSERT INTO event_counters (slot, seq) VALUES (?, 1) " +
              "ON CONFLICT(slot) DO UPDATE SET seq = seq + 1 RETURNING seq",
          )
          .get(slot) as { seq: number }
      ).seq;
      this.db
        .query(
          "INSERT INTO events (slot, seq, ts, type, data_json) VALUES (?, ?, ?, ?, ?)",
        )
        .run(slot, seq, Date.now(), type, JSON.stringify(data));
      // prune old events beyond the retention window
      this.db
        .query("DELETE FROM events WHERE slot = ? AND seq <= ?")
        .run(slot, seq - EVENT_LOG_KEEP);
      return seq;
    });
    const seq = tx();
    return {
      slot,
      seq,
      ts: Date.now(),
      type,
      data_json: JSON.stringify(data),
    };
  }

  latestSeq(slot: string): number {
    return (
      this.db
        .query("SELECT COALESCE(MAX(seq),0) s FROM events WHERE slot = ?")
        .get(slot) as { s: number }
    ).s;
  }

  minSeq(slot: string): number {
    return (
      this.db
        .query("SELECT COALESCE(MIN(seq),0) s FROM events WHERE slot = ?")
        .get(slot) as { s: number }
    ).s;
  }

  eventsSince(slot: string, sinceSeq: number): EventRow[] {
    return this.db
      .query("SELECT * FROM events WHERE slot = ? AND seq > ? ORDER BY seq")
      .all(slot, sinceSeq) as EventRow[];
  }

  close() {
    this.db.close();
  }
}
