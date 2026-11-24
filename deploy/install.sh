#!/usr/bin/env bash
# Idempotent installer for zalos. Run as root on a Linux host with systemd
# and Tailscale already connected.
set -euo pipefail

ZALOS_USER=zalos
INSTALL_DIR=/opt/zalos
DATA_DIR=/var/lib/zalos
UNIT=/etc/systemd/system/zalos.service
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUN_VERSION=1.4.4
BUN_BIN=/usr/local/bin/bun

die() { echo "error: $*" >&2; exit 1; }

ASSUME_YES=false
for a in "$@"; do [ "$a" = "--yes" ] && ASSUME_YES=true; done

confirm() {
  if $ASSUME_YES; then return 0; fi
  if [ ! -t 0 ]; then
    die "needs confirmation but there is no TTY; rerun with --yes"
  fi
  read -r -p "$1 [y/N] " a
  [ "$a" = "y" ] || [ "$a" = "Y" ] || die "aborted"
}

[ "$(uname -s)" = "Linux" ] || die "installer only runs on Linux"
[ "${EUID:-$(id -u)}" -eq 0 ] || die "run as root"
command -v systemctl >/dev/null || die "systemd not found"
# Tailscale CLI location is overridable (sidecar/container deployments).
TS_BIN="${ZALOS_TAILSCALE_BIN:-tailscale}"
TS_ARGS=()
[ -n "${ZALOS_TAILSCALE_SOCKET:-}" ] && TS_ARGS=(--socket "$ZALOS_TAILSCALE_SOCKET")
command -v "$TS_BIN" >/dev/null || die "tailscale not installed"
"$TS_BIN" "${TS_ARGS[@]}" status --json \
  | grep -Eq '"BackendState"[^,]*"Running"' \
  || die "tailscale is not running; run: tailscale up"

id "$ZALOS_USER" >/dev/null 2>&1 \
  || useradd --system --home "$DATA_DIR" --shell /usr/sbin/nologin "$ZALOS_USER"

# Bun runs system-wide at $BUN_BIN so the nologin service user needs no
# login shell and no per-user install.
if ! [ -x "$BUN_BIN" ]; then
  confirm "Bun is not installed at $BUN_BIN. Download bun v$BUN_VERSION from github.com/oven-sh/bun and install it system-wide?"
  case "$(uname -m)" in
    x86_64) BUN_ARCH=x64 ;;
    aarch64|arm64) BUN_ARCH=aarch64 ;;
    *) die "unsupported arch $(uname -m)" ;;
  esac
  command -v curl >/dev/null || die "curl not found"
  command -v unzip >/dev/null || die "unzip not found"
  command -v sha256sum >/dev/null || die "sha256sum not found"
  BASE="https://github.com/oven-sh/bun/releases/download/bun-v${BUN_VERSION}"
  ZIP="bun-linux-${BUN_ARCH}.zip"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  curl -fsSL "$BASE/$ZIP" -o "$work/$ZIP"
  curl -fsSL "$BASE/SHASUMS256.txt" -o "$work/SHASUMS256.txt"
  (cd "$work" && grep " $ZIP\$" SHASUMS256.txt | sha256sum -c -) \
    || die "bun archive checksum verification failed"
  unzip -q "$work/$ZIP" -d "$work"
  install -m 0755 "$work/bun-linux-${BUN_ARCH}/bun" "$BUN_BIN"
  rm -rf "$work"
  trap - EXIT
fi

mkdir -p "$INSTALL_DIR"
# /opt/zalos stays root-owned: the service user only reads it.
install -m 0644 "$SRC_DIR/server/package.json" "$SRC_DIR/server/bun.lock" "$INSTALL_DIR/"
rm -rf "$INSTALL_DIR/src" "$INSTALL_DIR/vendor"
cp -r "$SRC_DIR/server/src" "$INSTALL_DIR/src"
cp -r "$SRC_DIR/server/vendor" "$INSTALL_DIR/vendor"
chmod -R a+rX "$INSTALL_DIR"

mkdir -p "$INSTALL_DIR/bin"
printf '#!/usr/bin/env bash\nexec %s %s "$@"\n' "$BUN_BIN" "$INSTALL_DIR/src/cli.ts" \
  > "$INSTALL_DIR/bin/zalos"
chmod 755 "$INSTALL_DIR/bin/zalos"

mkdir -p "$DATA_DIR"
chown "$ZALOS_USER:$ZALOS_USER" "$DATA_DIR"
chmod 700 "$DATA_DIR"

(cd "$INSTALL_DIR" && "$BUN_BIN" install --frozen-lockfile --production)
chmod -R a+rX "$INSTALL_DIR/node_modules"

cp "$SRC_DIR/deploy/zalos.service" "$UNIT"
systemctl daemon-reload

TS_IP="$("$TS_BIN" "${TS_ARGS[@]}" ip -4 | head -n1)"
[ -n "$TS_IP" ] || die "could not resolve this node's Tailscale IPv4"

if ! sudo -u "$ZALOS_USER" ZALOS_DATA_DIR="$DATA_DIR" \
     ZALOS_TAILSCALE_BIN="$TS_BIN" ZALOS_TAILSCALE_SOCKET="${ZALOS_TAILSCALE_SOCKET:-}" \
     "$BUN_BIN" "$INSTALL_DIR/src/cli.ts" doctor --host "$TS_IP"; then
  echo "doctor reported critical failures; fix them before starting" >&2
  exit 1
fi

if systemctl is-active --quiet zalos.service; then
  systemctl restart zalos.service
else
  systemctl enable --now zalos.service
fi

echo
echo "zalos installed and running."
echo "next steps:"
echo "  sudo -u $ZALOS_USER $INSTALL_DIR/bin/zalos pair"
echo "  sudo -u $ZALOS_USER $INSTALL_DIR/bin/zalos accounts add"
