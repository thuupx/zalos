import { test, expect } from "bun:test";
import { runDoctor, type DoctorDeps } from "../src/doctor.ts";

const PROC_STATUS = `Name:\tzalos
NoNewPrivs:\t1
CapEff:\t0000000000000000
`;
const PROC_MOUNTS = `overlay / overlay ro,relatime 0 0\n`;

function stubDeps(extra: Partial<DoctorDeps> = {}): DoctorDeps {
  return {
    platform: "linux",
    uid: 10001,
    env: {},
    bunVersion: "1.4.4",
    statMode: (p) =>
      p.endsWith("server.key") || p.endsWith("zalos.db") ? 0o600 : 0o700,
    statUid: () => 10001,
    readFile: (p) =>
      p === "/proc/self/status"
        ? PROC_STATUS
        : p === "/proc/self/mounts"
          ? PROC_MOUNTS
          : null,
    run: async () => ({ code: 1, stdout: "", stderr: "no tailscale" }),
    ...extra,
  };
}

const LOCAL_ENV = { ZALOS_CONTAINER: "1", ZALOS_ALLOW_LOCAL: "1" };

test("local mode skips the tailnet checks and warns instead", async () => {
  const checks = await runDoctor({
    host: "0.0.0.0",
    port: 7443,
    dataDir: "/var/lib/zalos",
    deps: stubDeps({ env: LOCAL_ENV }),
  });
  const names = checks.map((c) => c.name);
  expect(names).not.toContain("tailscale running");
  expect(names).not.toContain("listen address is a tailscale ip");
  expect(names).not.toContain("tailscale funnel not exposing port");

  const local = checks.find((c) => c.name === "local mode: not on the tailnet");
  expect(local?.severity).toBe("warn");
  expect(local?.status).toBe("WARN");

  // The other criticals still apply and pass on a hardened container.
  const criticalFails = checks.filter(
    (c) => c.severity === "critical" && c.status === "FAIL",
  );
  expect(criticalFails.map((c) => c.name)).toEqual([]);
});

test("without the local opt-in a wildcard host still fails closed", async () => {
  const checks = await runDoctor({
    host: "0.0.0.0",
    port: 7443,
    dataDir: "/var/lib/zalos",
    deps: stubDeps({ env: { ZALOS_CONTAINER: "1" } }),
  });
  const listen = checks.find((c) => c.name === "listen address is a tailscale ip");
  expect(listen?.status).toBe("FAIL");
});

test("cli refuses --local outside the container opt-in", async () => {
  for (const env of [
    {},
    { ZALOS_CONTAINER: "1" },
    { ZALOS_ALLOW_LOCAL: "1" },
  ]) {
    const p = Bun.spawn(["bun", "src/cli.ts", "serve", "--local", "--port", "0"], {
      env: { ...process.env, ...env },
      stdout: "pipe",
      stderr: "pipe",
    });
    const code = await p.exited;
    const err = await new Response(p.stderr).text();
    expect(code).toBe(1);
    expect(err).toContain("--local requires ZALOS_CONTAINER=1 and ZALOS_ALLOW_LOCAL=1");
  }
});
