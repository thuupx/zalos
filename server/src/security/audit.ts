// Structured redacting logger and security audit event emitter.
// Never logs credentials, tokens, cookies, PINs, PSKs, vault roots, or
// message bodies.

export type AuditOutcome = "ok" | "denied" | "error";

export type AuditEvent = {
  ts: string;
  event: string;
  outcome: AuditOutcome;
  deviceId?: string | null;
  role?: string | null;
  slot?: string | null;
  method?: string | null;
  reason?: string | null;
};

type AuditSink = (entry: AuditEvent) => void;
type ErrorLogSink = (entry: Record<string, unknown>) => void;

let auditSink: AuditSink | null = null;
let errorLogSink: ErrorLogSink | null = null;

export function setAuditSink(sink: AuditSink | null) {
  auditSink = sink;
}

export function setErrorLogSink(sink: ErrorLogSink | null) {
  errorLogSink = sink;
}

const SENSITIVE_KEY_RE =
  /(cookie|authorization|access_?token|refresh_?token|app_?secret|secret_?key|secret|password|passwd|pin\b|psk|private_?key|vault_?root|credential|wrapped|body|text|content)/i;

const QUERY_SECRET_RE =
  /([?&](?:access_token|refresh_token|token|secret|key|psk|pin|password|cookie)=)[^&\s"'<>]+/gi;

const BEARER_RE = /\b(Bearer|Basic)\s+[A-Za-z0-9._~+/=-]{6,}/gi;

export function redactString(input: string): string {
  return input
    .replace(QUERY_SECRET_RE, "$1[REDACTED]")
    .replace(BEARER_RE, "$1 [REDACTED]");
}

export function redactValue(value: unknown, depth = 0): unknown {
  if (depth > 6) return "[TRUNCATED]";
  if (value === null || value === undefined) return value;
  if (typeof value === "string") return redactString(value);
  if (typeof value === "number" || typeof value === "boolean") return value;
  if (value instanceof Error) {
    const code = (value as Error & { code?: unknown }).code;
    return {
      name: value.name,
      message: redactString(value.message),
      code: typeof code === "string" || typeof code === "number" ? code : undefined,
    };
  }
  if (Array.isArray(value)) {
    return value.slice(0, 20).map((item) => redactValue(item, depth + 1));
  }
  if (typeof value === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
      out[k] = SENSITIVE_KEY_RE.test(k) ? "[REDACTED]" : redactValue(v, depth + 1);
    }
    return out;
  }
  return String(value);
}

export function auditEvent(
  evt: Omit<AuditEvent, "ts"> & { ts?: string },
) {
  const entry: AuditEvent = {
    ts: evt.ts ?? new Date().toISOString(),
    event: evt.event,
    outcome: evt.outcome,
    ...(evt.deviceId !== undefined ? { deviceId: evt.deviceId } : {}),
    ...(evt.role !== undefined ? { role: evt.role } : {}),
    ...(evt.slot !== undefined ? { slot: evt.slot } : {}),
    ...(evt.method !== undefined ? { method: evt.method } : {}),
    ...(evt.reason !== undefined && evt.reason !== null
      ? { reason: redactString(evt.reason) }
      : {}),
  };
  if (auditSink !== null) {
    auditSink(entry);
    return;
  }
  if (process.env.ZALOS_AUDIT_LOG === "1") {
    console.error(JSON.stringify({ kind: "audit", ...entry }));
  }
}

export function logSafeError(
  context: string,
  err: unknown,
  meta: Record<string, unknown> = {},
) {
  const safeMeta = redactValue(meta) as Record<string, unknown>;
  const safeErr = redactValue(err);
  const entry: Record<string, unknown> = {
    ts: new Date().toISOString(),
    kind: "error",
    context,
    error: safeErr,
    ...safeMeta,
  };
  if (errorLogSink !== null) {
    errorLogSink(entry);
    return;
  }
  console.error(JSON.stringify(entry));
}
