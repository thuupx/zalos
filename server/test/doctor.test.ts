import { test, expect } from "bun:test";
import { runDoctor, type DoctorDeps } from "../src/doctor.ts";

function stubDeps(over: Partial<DoctorDeps> = {}): DoctorDeps {
  return {
    platform: "linux",
    uid: 1000,
    env: {},
    bunVersion: "1.4.4",
    statMode: (p) =>
      p.endsWith("server.key") || p.endsWith("zalos.db") ? 0o600 : 0o700,
    statUid: () => 1000,
    readFile: () => null,
    run: async (cmd) => {
      const c = cmd.join(" ");
      if (c === "tailscale status --json") {
        return { code: 0, stdout: '{"BackendState":"Running"}', stderr: "" };
      }
      if (c === "tailscale ip") {
        return { code: 0, stdout: "100.64.1.2\nfd7a::2\n", stderr: "" };
      }
      if (c.startsWith("tailscale funnel")) {
        return { code: 0, stdout: "{}", stderr: "" };
      }
      if (c.startsWith("timedatectl")) {
        return { code: 0, stdout: "NTPSynchronized=yes\n", stderr: "" };
      }
      return { code: 0, stdout: "", stderr: "" };
    },
    ...over,
  };
}

const base = { host: "100.64.1.2", port: 7443, dataDir: "/var/lib/zalos" };

const find = (checks: { name: string; status: string }[], n: string) =>
  checks.find((c) => c.name === n)!;

test("all critical checks pass on a healthy stub", async () => {
  const checks = await runDoctor({ ...base, deps: stubDeps() });
  for (const n of [
    "platform is linux",
    "tailscale running",
    "listen address is a tailscale ip",
    "not running as root",
    "data dir is 0700 and owned by this user",
    "server.key is 0600",
    "database is 0600",
    "tailscale funnel not exposing port",
  ]) {
    expect(find(checks, n).status).toBe("PASS");
  }
});

test("each critical check fails appropriately", async () => {
  let checks = await runDoctor({
    ...base,
    deps: stubDeps({ platform: "darwin" }),
  });
  expect(find(checks, "platform is linux").status).toBe("FAIL");

  checks = await runDoctor({
    ...base,
    deps: stubDeps({
      run: async () => ({ code: 0, stdout: '{"BackendState":"Stopped"}', stderr: "" }),
    }),
  });
  expect(find(checks, "tailscale running").status).toBe("FAIL");

  // wildcard and non-tailscale listen addresses
  for (const host of ["0.0.0.0", "::", "192.168.1.5"]) {
    checks = await runDoctor({ ...base, host, deps: stubDeps() });
    expect(find(checks, "listen address is a tailscale ip").status).toBe("FAIL");
  }

  checks = await runDoctor({ ...base, deps: stubDeps({ uid: 0 }) });
  expect(find(checks, "not running as root").status).toBe("FAIL");

  checks = await runDoctor({
    ...base,
    deps: stubDeps({ statMode: () => 0o755 }),
  });
  expect(find(checks, "data dir is 0700 and owned by this user").status).toBe(
    "FAIL",
  );
  expect(find(checks, "server.key is 0600").status).toBe("FAIL");

  checks = await runDoctor({
    ...base,
    deps: stubDeps({
      statMode: (p) => (p.endsWith("server.key") ? 0o644 : 0o700),
    }),
  });
  expect(find(checks, "server.key is 0600").status).toBe("FAIL");

  checks = await runDoctor({
    ...base,
    deps: stubDeps({
      run: async (cmd) => {
        if (cmd.join(" ").startsWith("tailscale funnel")) {
          return {
            code: 0,
            stdout: JSON.stringify({
              AllowFunnel: { "node.ts.net:443": true },
              Web: { "node.ts.net:443": { Handlers: { "/": { Proxy: "http://127.0.0.1:7443" } } } },
            }),
            stderr: "",
          };
        }
        return { code: 0, stdout: "{}", stderr: "" };
      },
    }),
  });
  expect(find(checks, "tailscale funnel not exposing port").status).toBe("FAIL");

  // Funnel status command failure must fail closed.
  checks = await runDoctor({
    ...base,
    deps: stubDeps({
      run: async (cmd) => {
        if (cmd.join(" ").startsWith("tailscale funnel")) {
          return { code: 1, stdout: "", stderr: "socket denied" };
        }
        return { code: 0, stdout: "{}", stderr: "" };
      },
    }),
  });
  expect(find(checks, "tailscale funnel not exposing port").status).toBe("FAIL");
});

const PROC_STATUS_SECURE = `Name:\tzalos
NoNewPrivs:\t1
CapInh:\t0000000000000000
CapPrm:\t0000000000000000
CapEff:\t0000000000000000
`;
const PROC_MOUNTS_RO = `overlay / overlay ro,relatime,lowerdir=/l 0 0
proc /proc proc rw,nosuid 0 0
`;

test("container mode enforces sandbox criticals from /proc", async () => {
  const env = { ZALOS_CONTAINER: "1" };
  const files = (status: string | null, mounts: string | null) =>
    stubDeps({
      env,
      readFile: (p) =>
        p === "/proc/self/status" ? status : p === "/proc/self/mounts" ? mounts : null,
    });

  // Fully hardened container passes all three container checks.
  let checks = await runDoctor({
    ...base,
    deps: files(PROC_STATUS_SECURE, PROC_MOUNTS_RO),
  });
  for (const n of [
    "container: no new privileges",
    "container: no effective capabilities",
    "container: root filesystem read-only",
  ]) {
    expect(find(checks, n).status).toBe("PASS");
  }
  // The systemd sandbox warnings must not appear in container mode.
  expect(checks.some((c) => c.name.startsWith("systemd"))).toBe(false);

  // Missing NoNewPrivs, capabilities present, rw rootfs all fail closed.
  checks = await runDoctor({
    ...base,
    deps: files(
      PROC_STATUS_SECURE.replace("NoNewPrivs:\t1", "NoNewPrivs:\t0"),
      PROC_MOUNTS_RO,
    ),
  });
  expect(find(checks, "container: no new privileges").status).toBe("FAIL");

  checks = await runDoctor({
    ...base,
    deps: files(
      PROC_STATUS_SECURE.replace(
        "CapEff:\t0000000000000000",
        "CapEff:\t0000000000000001",
      ),
      PROC_MOUNTS_RO,
    ),
  });
  expect(find(checks, "container: no effective capabilities").status).toBe(
    "FAIL",
  );

  checks = await runDoctor({
    ...base,
    deps: files(
      PROC_STATUS_SECURE,
      PROC_MOUNTS_RO.replace("ro,relatime", "rw,relatime"),
    ),
  });
  expect(find(checks, "container: root filesystem read-only").status).toBe(
    "FAIL",
  );

  // Unreadable /proc fails closed too.
  checks = await runDoctor({ ...base, deps: files(null, null) });
  expect(find(checks, "container: no new privileges").status).toBe("FAIL");
  expect(find(checks, "container: no effective capabilities").status).toBe(
    "FAIL",
  );
  expect(find(checks, "container: root filesystem read-only").status).toBe(
    "FAIL",
  );

  // The other critical checks still apply inside the container.
  expect(find(checks, "not running as root").status).toBe("PASS");
  expect(find(checks, "tailscale funnel not exposing port").status).toBe(
    "PASS",
  );
});
