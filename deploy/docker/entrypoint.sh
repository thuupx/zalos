#!/bin/sh
# Waits for the sidecar tailscaled, then runs the production server.
set -eu

# Pass-through so operators can run `docker compose run zalos zalos pair`,
# `zalos doctor`, the smoke script, etc.
if [ "$#" -gt 0 ]; then
  exec "$@"
fi

SOCKET="${ZALOS_TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
PORT="${ZALOS_PORT:-7443}"

ts_running() {
  tailscale --socket "$SOCKET" status --json 2>/dev/null \
    | grep -q '"BackendState"[^,]*"Running"'
}

echo "waiting for tailscale (approve the login URL in the tailscale container logs)"
i=0
while [ "$i" -lt 30 ]; do
  if ts_running; then
    break
  fi
  i=$((i + 1))
  echo "still waiting for tailscale ($i/30); run 'docker compose logs tailscale' for the login URL"
  sleep 10
done

if ! ts_running; then
  echo "tailscale did not report Running within 5 minutes; exiting" >&2
  exit 1
fi

echo "tailscale is up; starting zalos on port $PORT"
exec zalos serve --port "$PORT"
