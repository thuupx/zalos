// Preflight checks for the non-dev serve path. Every external command goes
// through `deps.run` so tests can stub them on any platform.
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fingerprint } from "./store/db.ts";

export type Severity = "critical" | "warn";

export type Check = {
  name: string;
  severity: Severity;
  status: "PASS" | "WARN" | "FAIL";
  message: string;
  fix: string;
};

export type RunResult = { code: number; stdout: string; stderr: string };

export type DoctorDeps = {
  platform: NodeJS.Platform;
  uid: number | null;
  env: NodeJS.ProcessEnv;
  run(cmd: string[]): Promise<RunResult>;
  statMode(path: string): number | null;
  statUid(path: string): number | null;
  readFile(path: string): string | null;
  bunVersion: string;
};

export function defaultDeps(): DoctorDeps {
  return {
    platform: process.platform,
    uid: typeof process.getuid === "function" ? process.getuid() : null,
    env: process.env,
    bunVersion: Bun.version,
    run: async (cmd) => {
      try {
        const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe" });
        const code = await p.exited;
        return {
          code,
          stdout: await new Response(p.stdout).text(),
          stderr: await new Response(p.stderr).text(),
        };
      } catch {
        return { code: 127, stdout: "", stderr: "command not found" };
      }
    },
    statMode: (p) => {
      try {
        return statSync(p).mode & 0o777;
      } catch {
        return null;
      }
    },
    statUid: (p) => {
      try {
        return statSync(p).uid;
      } catch {
        return null;
      }
    },
    readFile: (p) => {
      try {
        return readFileSync(p, "utf-8");
      } catch {
        return null;
      }
    },
  };
}

const c = (
  name: string,
  status: Check["status"],
  message: string,
  fix: string,
): Check => ({
  name,
  severity: status === "WARN" ? "warn" : "critical",
  status,
  message,
  fix,
});

const crit = (name: string, ok: boolean, msg: string, fix: string): Check =>
  c(name, ok ? "PASS" : "FAIL", msg, fix);
const warn = (name: string, ok: boolean, msg: string, fix: string): Check => ({
  name,
  severity: "warn",
  status: ok ? "PASS" : "WARN",
  message: msg,
  fix,
});

// Tailscale CLI location: overridable for containers/sidecars where the
// binary or the control socket lives elsewhere (Docker deployment).
export function tailscaleCmd(deps: DoctorDeps, args: string[]): string[] {
  const bin = deps.env.ZALOS_TAILSCALE_BIN ?? "tailscale";
  const socket = deps.env.ZALOS_TAILSCALE_SOCKET;
  return socket === undefined || socket === ""
    ? [bin, ...args]
    : [bin, "--socket", socket, ...args];
}

export async function tailscaleIps(deps: DoctorDeps): Promise<string[]> {
  const r = await deps.run(tailscaleCmd(deps, ["ip"]));
  if (r.code !== 0) return [];
  return r.stdout
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "");
}

export async function tailscaleIPv4(deps: DoctorDeps): Promise<string | null> {
  const ips = await tailscaleIps(deps);
  return ips.find((i) => !i.includes(":")) ?? null;
}

// Structurally parse `tailscale funnel status --json` and fail closed:
// returns `true` (exposed/unsafe) if Funnel exposes `port` or JSON is invalid.
export function parseFunnelStatus(
  stdout: string,
  port: number,
): { ok: boolean; exposed: boolean; reason: string } {
  const trimmed = stdout.trim();
  if (trimmed === "" || trimmed === "{}") {
    return { ok: true, exposed: false, reason: "no funnel on the port" };
  }
  let parsed: Record<string, unknown>;
  try {
    const val = JSON.parse(trimmed);
    if (val === null || typeof val !== "object" || Array.isArray(val)) {
      return { ok: false, exposed: true, reason: "unparseable funnel status JSON" };
    }
    parsed = val as Record<string, unknown>;
  } catch {
    return { ok: false, exposed: true, reason: "invalid funnel status JSON" };
  }
  const allowFunnel = parsed.AllowFunnel;
  const hasAnyFunnel =
    allowFunnel !== null &&
    typeof allowFunnel === "object" &&
    Object.values(allowFunnel as Record<string, unknown>).some((v) => v === true);
  if (!hasAnyFunnel) {
    return { ok: true, exposed: false, reason: "no funnel enabled" };
  }
  const portNeedle = `:${port}`;
  const jsonText = JSON.stringify(parsed);
  if (jsonText.includes(portNeedle)) {
    return { ok: true, exposed: true, reason: `funnel exposes :${port}` };
  }
  return { ok: true, exposed: false, reason: "no funnel on the port" };
}

export async function runDoctor(opts: {
  host: string;
  port: number;
  dataDir: string;
  deps?: DoctorDeps;
}): Promise<Check[]> {
  const deps = opts.deps ?? defaultDeps();
  const checks: Check[] = [];

  checks.push(
    crit(
      "platform is linux",
      deps.platform === "linux",
      deps.platform === "linux" ? "linux" : `platform ${deps.platform}`,
      "run zalos on a Linux machine",
    ),
  );

  // Local-container development mode (`serve --local`): no Tailscale is
  // expected, so the tailnet checks are skipped and replaced by a warning.
  // Every other check, including the container sandbox checks, stays.
  const localMode =
    deps.env.ZALOS_CONTAINER === "1" && deps.env.ZALOS_ALLOW_LOCAL === "1";
  if (localMode) {
    checks.push(
      warn(
        "local mode: not on the tailnet",
        false,
        "bound to 0.0.0.0 inside the container; the only network protection is a loopback-only port publish on the host",
        "use the tailscale sidecar deployment for real use",
      ),
    );
  } else {
    const status = await deps.run(tailscaleCmd(deps, ["status", "--json"]));
    let backend = "";
    try {
      backend = String(
        (JSON.parse(status.stdout) as { BackendState?: string }).BackendState ??
          "",
      );
    } catch {
      backend = "";
    }
    checks.push(
      crit(
        "tailscale running",
        status.code === 0 && backend === "Running",
        status.code !== 0 ? "tailscale CLI not available" : `BackendState=${backend || "?"}`,
        "install Tailscale and run `tailscale up`",
      ),
    );

    const ips = await tailscaleIps(deps);
    const wildcard = opts.host === "0.0.0.0" || opts.host === "::";
    checks.push(
      crit(
        "listen address is a tailscale ip",
        !wildcard && ips.includes(opts.host),
        wildcard
          ? `wildcard host ${opts.host}`
          : ips.includes(opts.host)
            ? `${opts.host} is a tailscale ip`
            : `${opts.host} not in ${ips.join(", ") || "(none)"}`,
        "bind to this node's `tailscale ip -4` address",
      ),
    );
  }

  checks.push(
    crit(
      "not running as root",
      deps.uid !== 0,
      deps.uid === 0 ? "running as root" : `uid ${deps.uid}`,
      "run as a dedicated user (see deploy/zalos.service)",
    ),
  );

  const dirMode = deps.statMode(opts.dataDir);
  const dirUid = deps.statUid(opts.dataDir);
  const uid = deps.uid ?? -1;
  checks.push(
    crit(
      "data dir is 0700 and owned by this user",
      dirMode === 0o700 && dirUid === uid,
      dirMode === null
        ? "data dir missing"
        : `mode ${dirMode.toString(8)} uid ${dirUid}`,
      "chmod 700 <data-dir> && chown $(id -u) <data-dir>",
    ),
  );

  for (const [label, p] of [
    ["server.key", join(opts.dataDir, "server.key")],
    ["database", join(opts.dataDir, "zalos.db")],
  ] as const) {
    const m = deps.statMode(p);
    checks.push(
      crit(
        `${label} is 0600`,
        m === null || m === 0o600,
        m === null ? "not created yet" : `mode ${m.toString(8)}`,
        `chmod 600 ${p}`,
      ),
    );
  }

  if (!localMode) {
    const funnel = await deps.run(
      tailscaleCmd(deps, ["funnel", "status", "--json"]),
    );
    const parsed =
      funnel.code !== 0
        ? {
            ok: false,
            exposed: true,
            reason: `tailscale funnel status failed (exit ${funnel.code})`,
          }
        : parseFunnelStatus(funnel.stdout, opts.port);
    checks.push(
      crit(
        "tailscale funnel not exposing port",
        parsed.ok && !parsed.exposed,
        parsed.reason,
        `tailscale funnel --bg --https=443 off  # or verify tailscale status`,
      ),
    );
  }

  const ntp = await deps.run(["timedatectl", "show", "-p", "NTPSynchronized"]);
  checks.push(
    warn(
      "clock synchronized",
      ntp.code === 0 && ntp.stdout.includes("NTPSynchronized=yes"),
      ntp.stdout.trim() || "timedatectl unavailable",
      "enable NTP (timedatectl set-ntp true)",
    ),
  );

  const unit = deps.env.ZALOS_UNIT;
  if (deps.env.ZALOS_CONTAINER === "1") {
    // Container deployment (deploy/docker): the sandbox is enforced by the
    // container runtime, so the guarantees are read back from /proc and the
    // mount table and are critical, not warnings.
    const status = deps.readFile("/proc/self/status");
    const noNewPrivs = /^NoNewPrivs:\s*1$/m.test(status ?? "");
    checks.push(
      crit(
        "container: no new privileges",
        noNewPrivs,
        noNewPrivs ? "NoNewPrivs=1" : "NoNewPrivs unset",
        "security_opt: [no-new-privileges:true]",
      ),
    );
    const capEff = /^CapEff:\s*([0-9a-fA-F]+)$/m.exec(status ?? "");
    const noCaps = capEff !== null && BigInt(`0x${capEff[1]}`) === 0n;
    checks.push(
      crit(
        "container: no effective capabilities",
        noCaps,
        capEff === null ? "CapEff unreadable" : `CapEff=${capEff[1]}`,
        "cap_drop: [ALL]",
      ),
    );
    const mounts = deps.readFile("/proc/self/mounts");
    const rootRo =
      mounts !== null &&
      mounts
        .split("\n")
        .some((l) => l.split(" ")[1] === "/" && (l.split(" ")[3] ?? "").split(",").includes("ro"));
    checks.push(
      crit(
        "container: root filesystem read-only",
        rootRo,
        rootRo ? "ro" : "root mount is rw or unreadable",
        "read_only: true",
      ),
    );
  } else if (deps.env.INVOCATION_ID === undefined && unit === undefined) {
    checks.push(
      warn(
        "systemd sandbox",
        false,
        "not running under systemd",
        "deploy via deploy/install.sh and the zalos.service unit",
      ),
    );
  } else {
    const name = unit ?? "zalos.service";
    const show = await deps.run([
      "systemctl",
      "show",
      name,
      "-p",
      "NoNewPrivileges,ProtectSystem,ProtectHome,PrivateTmp,PrivateDevices,RestrictAddressFamilies",
    ]);
    for (const [directive, want] of [
      ["NoNewPrivileges", "yes"],
      ["ProtectSystem", "strict"],
      ["ProtectHome", "yes"],
      ["PrivateTmp", "yes"],
      ["PrivateDevices", "yes"],
      ["RestrictAddressFamilies", "AF_"],
    ] as const) {
      const m = new RegExp(`${directive}=([^\\n]+)`).exec(show.stdout);
      const ok = show.code === 0 && m !== null && m[1].includes(want);
      checks.push(
        crit(
          `systemd sandbox: ${directive}`,
          ok,
          ok ? `${directive}=${m![1]}` : `${directive} missing`,
          "use the zalos.service unit from deploy/",
        ),
      );
    }
  }

  // The service user should not have a login shell (not applicable inside
  // the container, where the image has no getent).
  const passwd =
    deps.env.ZALOS_CONTAINER === "1"
      ? { code: 127, stdout: "", stderr: "" }
      : await deps.run(["getent", "passwd", "zalos"]);
  if (passwd.code === 0 && passwd.stdout.trim() !== "") {
    const shell = passwd.stdout.trim().split(":").at(-1) ?? "";
    checks.push(
      warn(
        "service user has no login shell",
        /nologin|false$/.test(shell),
        `shell ${shell}`,
        "usermod -s /usr/sbin/nologin zalos",
      ),
    );
  }

  // Show the server key fingerprint when the key already exists.
  try {
    const keyJson = JSON.parse(
      readFileSync(join(opts.dataDir, "server.key"), "utf-8"),
    ) as { public?: string };
    if (typeof keyJson.public === "string") {
      checks.push({
        name: "server key fingerprint",
        severity: "warn",
        status: "PASS",
        message: fingerprint(keyJson.public),
        fix: "",
      });
    }
  } catch {}

  const [maj, min] = deps.bunVersion.split(".").map(Number);
  checks.push(
    warn(
      "bun >= 1.4",
      maj > 1 || (maj === 1 && min >= 4),
      `bun ${deps.bunVersion}`,
      "upgrade Bun: bun upgrade",
    ),
  );

  if (!localMode) {
    checks.push({
      name: "tailscale acl reminder",
      severity: "warn",
      status: "WARN",
      message: "verify your tailnet ACLs restrict the zalos port",
      fix: "review tailnet ACLs in the admin console",
    });
  }

  return checks;
}

export function printChecks(checks: Check[]): boolean {
  let critical = false;
  for (const chk of checks) {
    const sev = chk.severity === "critical" ? "critical" : "warn    ";
    console.log(`${chk.status}  [${sev}] ${chk.name}: ${chk.message}`);
    if (chk.status !== "PASS") {
      console.log(`       fix: ${chk.fix}`);
    }
    if (chk.severity === "critical" && chk.status === "FAIL") critical = true;
  }
  return critical;
}
