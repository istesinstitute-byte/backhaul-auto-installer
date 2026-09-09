#!/usr/bin/env bash
set -Eeuo pipefail

VERSION="${BACKHAUL_VERSION:-0.7.2}"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo -e "\n==> $*"; }

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E bash "$0" "$@"
fi

command -v apt-get >/dev/null 2>&1 || die "This script supports Ubuntu/Debian only."

case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) die "Unsupported architecture: $(uname -m)" ;;
esac

read -r -p "Iran server public IP: " IRAN_IP
[[ -n "$IRAN_IP" ]] || die "IP cannot be empty."

read -r -p "Backhaul control port on Iran [443]: " CONTROL_PORT
CONTROL_PORT="${CONTROL_PORT:-443}"

read -r -p "Local target host on this foreign server [127.0.0.1]: " TARGET_HOST
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"

read -r -p "Local target port on this foreign server [2053]: " TARGET_PORT
TARGET_PORT="${TARGET_PORT:-2053}"

read -r -s -p "64-character token from Iran server: " TOKEN
echo
[[ "${#TOKEN}" -eq 64 ]] || die "Token must be exactly 64 characters. Current length: ${#TOKEN}"

info "Installing prerequisites"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates netcat-openbsd

info "Testing TCP connectivity to Iran server"
nc -vz -w 8 "$IRAN_IP" "$CONTROL_PORT" || die "TCP connection to ${IRAN_IP}:${CONTROL_PORT} failed."

if ! nc -z -w 3 "$TARGET_HOST" "$TARGET_PORT"; then
  echo
  echo "WARNING: local target ${TARGET_HOST}:${TARGET_PORT} is not currently accepting connections."
  echo "For Xray, the inbound should usually listen on 127.0.0.1:${TARGET_PORT}."
  read -r -p "Continue anyway? [y/N]: " CONTINUE
  [[ "$CONTINUE" =~ ^[Yy]$ ]] || die "Installation stopped."
else
  echo "Local target ${TARGET_HOST}:${TARGET_PORT} is reachable."
fi

info "Installing Backhaul v${VERSION} (${ARCH})"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
URL="https://github.com/Musixal/Backhaul/releases/download/v${VERSION}/backhaul_linux_${ARCH}.tar.gz"
curl -fL --retry 5 --connect-timeout 15 -o "$TMPDIR/backhaul.tgz" "$URL"
tar -xzf "$TMPDIR/backhaul.tgz" -C "$TMPDIR"
install -m 0755 "$TMPDIR/backhaul" /usr/local/bin/backhaul
/usr/local/bin/backhaul -v

STAMP="$(date +%Y%m%d-%H%M%S)"
if [[ -d /etc/backhaul ]]; then
  info "Backing up previous Backhaul configuration"
  cp -a /etc/backhaul "/etc/backhaul.backup-${STAMP}"
fi
mkdir -p /etc/backhaul
chmod 700 /etc/backhaul

systemctl disable --now backhaul-client.service >/dev/null 2>&1 || true

info "Creating Backhaul client configuration"
cat > /etc/backhaul/client.toml <<EOF
[client]
remote_addr = "${IRAN_IP}:${CONTROL_PORT}"
edge_ip = ""
transport = "wssmux"
token = "${TOKEN}"

connection_pool = 8
aggressive_pool = false

keepalive_period = 75
dial_timeout = 10
retry_interval = 3
nodelay = true

mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

sniffer = false
web_port = 0
log_level = "info"
EOF
chmod 600 /etc/backhaul/client.toml

info "Creating persistent systemd service"
cat > /etc/systemd/system/backhaul-client.service <<'EOF'
[Unit]
Description=Backhaul WSSMux Client - Foreign Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/client.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

echo
echo "IMPORTANT: If an old foreign Backhaul Client using the same token is still running,"
echo "starting this Client at the same time may move/reset the control channel."
read -r -p "Is the old Client stopped, and should this Client be enabled and started now? [y/N]: " START_NOW

if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
  systemctl enable --now backhaul-client.service
  sleep 2

  info "Final status"
  systemctl --no-pager --full status backhaul-client.service || true
  echo
  journalctl -u backhaul-client.service -n 20 --no-pager || true
  echo
  if journalctl -u backhaul-client.service -n 50 --no-pager | grep -q "control channel established successfully"; then
    echo "SUCCESS: Backhaul control channel established successfully."
  else
    echo "WARNING: control-channel success message not found yet. Review the log above."
  fi
else
  systemctl disable backhaul-client.service >/dev/null 2>&1 || true
  echo
  echo "Configuration and service were created, but the Client was not started/enabled."
  echo "At cutover, after stopping the old Client, run:"
  echo "  systemctl enable --now backhaul-client"
fi

echo
echo "============================================================"
echo "Backhaul Client setup complete."
echo "Iran endpoint : ${IRAN_IP}:${CONTROL_PORT}"
echo "Local target  : ${TARGET_HOST}:${TARGET_PORT}"
echo "Config        : /etc/backhaul/client.toml"
echo "============================================================"
