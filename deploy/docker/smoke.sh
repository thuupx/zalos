#!/bin/sh
# Builds the zalos image and runs the self-contained smoke check (no
# Tailscale needed). Exits non-zero on any failure.
set -eu

cd "$(dirname "$0")"

echo "== building zalos:local =="
docker build -f Dockerfile -t zalos:local ../..

echo "== running in-container smoke (dev+fake, read-only rootfs) =="
docker run --rm \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --user 10001 \
  -v /var/lib/zalos \
  --entrypoint /opt/zalos/smoke/run.sh \
  zalos:local

echo "== image runs as uid 10001 =="
uid="$(docker run --rm --entrypoint id zalos:local -u)"
[ "$uid" = "10001" ] || { echo "expected uid 10001, got $uid" >&2; exit 1; }
echo "uid=$uid"

echo "== root filesystem is read-only =="
if docker run --rm --read-only --entrypoint sh zalos:local -c 'touch /w' 2>/dev/null; then
  echo "root filesystem is writable" >&2
  exit 1
fi
echo "ro ok"

echo "== doctor fails closed without tailscale (container mode) =="
if docker run --rm --entrypoint zalos zalos:local doctor 2>/dev/null; then
  echo "doctor passed without tailscale" >&2
  exit 1
fi
echo "doctor failed closed as expected"

echo "== local variant: serve --local behind a loopback publish =="
docker rm -fv zalos-smoke-local >/dev/null 2>&1 || true
docker run -d --name zalos-smoke-local \
  --read-only \
  --tmpfs /tmp \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  -p 127.0.0.1:7443:7443 \
  -e ZALOS_ALLOW_LOCAL=1 \
  -v /var/lib/zalos \
  --entrypoint zalos \
  zalos:local serve --local >/dev/null
trap 'docker rm -fv zalos-smoke-local >/dev/null 2>&1 || true' EXIT

i=0
until docker exec zalos-smoke-local zalos health >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 60 ]; then
    echo "local server did not come up:" >&2
    docker logs zalos-smoke-local >&2
    exit 1
  fi
  sleep 1
done
echo "health ok"

URI="$(docker exec zalos-smoke-local zalos pair | grep '^zalos://' | head -n1)"
[ -n "$URI" ] || { echo "no pairing uri" >&2; exit 1; }
case "$URI" in
  *"host=127.0.0.1"*) ;;
  *) echo "pairing uri does not carry the public host: $URI" >&2; exit 1 ;;
esac
bun smoke/handshake.ts "$URI"

LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || true)"
[ -n "$LAN_IP" ] || LAN_IP="$(ifconfig 2>/dev/null | awk '/inet / && $2 != "127.0.0.1" {print $2; exit}')"
if [ -n "$LAN_IP" ]; then
  if nc -z -w 2 "$LAN_IP" 7443 2>/dev/null; then
    echo "port 7443 reachable on non-loopback address $LAN_IP" >&2
    exit 1
  fi
  echo "not reachable on $LAN_IP (loopback-only publish)"
else
  echo "no non-loopback address found; skipping reachability check"
fi

docker rm -fv zalos-smoke-local >/dev/null 2>&1 || true
trap - EXIT

echo "SMOKE SUITE OK"
