#!/bin/sh
# Runs inside the image: starts a dev+fake server, then drives the smoke
# client against it over loopback. Exits non-zero on any failure.
set -eu

export ZALOS_DATA_DIR="${ZALOS_DATA_DIR:-/var/lib/zalos}"
mkdir -p "$ZALOS_DATA_DIR" 2>/dev/null || true

bun /opt/zalos/src/cli.ts serve --dev --fake --port 7443 >/tmp/serve.log 2>&1 &
SPID=$!
trap 'kill "$SPID" 2>/dev/null || true' EXIT

i=0
until grep -q "zalos listening" /tmp/serve.log 2>/dev/null; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "server did not start:" >&2
    cat /tmp/serve.log >&2
    exit 1
  fi
  if ! kill -0 "$SPID" 2>/dev/null; then
    echo "server exited early:" >&2
    cat /tmp/serve.log >&2
    exit 1
  fi
  sleep 1
done

URI="$(bun /opt/zalos/src/cli.ts pair --role admin | grep '^zalos://' | head -n1)"
bun /opt/zalos/smoke/smoke.ts "$URI" "$ZALOS_DATA_DIR"
