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

read -r -p "Backhaul control port [443]: " CONTROL_PORT
CONTROL_PORT="${CONTROL_PORT:-443}"

read -r -p "Public client port on Iran [2053]: " PUBLIC_PORT
PUBLIC_PORT="${PUBLIC_PORT:-2053}"

read -r -p "Target host on foreign server [127.0.0.1]: " TARGET_HOST
TARGET_HOST="${TARGET_HOST:-127.0.0.1}"

read -r -p "Target port on foreign server [2053]: " TARGET_PORT
TARGET_PORT="${TARGET_PORT:-2053}"

read -r -s -p "Enter a 64-character token, or press Enter to generate one: " TOKEN
echo

info "Installing prerequisites"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl tar ca-certificates openssl ufw

if [[ -z "$TOKEN" ]]; then
  TOKEN="$(openssl rand -hex 32)"
  echo "A secure 64-character token was generated."
elif [[ "${#TOKEN}" -ne 64 ]]; then
  die "Token must be exactly 64 characters. Current length: ${#TOKEN}"
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
mkdir -p /etc/backhaul/tls
chmod 700 /etc/backhaul

systemctl disable --now backhaul-server.service >/dev/null 2>&1 || true

for P in "$CONTROL_PORT" "$PUBLIC_PORT"; do
  if ss -lntp 2>/dev/null | grep -Eq ":${P}[[:space:]]"; then
    echo
    ss -lntp | grep -E ":${P}[[:space:]]" || true
    die "Port ${P} is already in use by another service."
  fi
done

info "Creating self-signed TLS certificate"
openssl req \
  -x509 \
  -newkey rsa:2048 \
  -sha256 \
  -nodes \
  -days 825 \
  -keyout /etc/backhaul/tls/server.key \
  -out /etc/backhaul/tls/server.crt \
  -subj "/CN=${IRAN_IP}" \
  -addext "subjectAltName=IP:${IRAN_IP}"

chmod 600 /etc/backhaul/tls/server.key
chmod 644 /etc/backhaul/tls/server.crt
printf '%s' "$TOKEN" > /etc/backhaul/token
chmod 600 /etc/backhaul/token

info "Creating Backhaul server configuration"
cat > /etc/backhaul/server.toml <<EOF
[server]
bind_addr = "0.0.0.0:${CONTROL_PORT}"
transport = "wssmux"
token = "${TOKEN}"

keepalive_period = 75
heartbeat = 40
nodelay = true
channel_size = 2048

mux_con = 8
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 4194304
mux_streambuffer = 65536

tls_cert = "/etc/backhaul/tls/server.crt"
tls_key = "/etc/backhaul/tls/server.key"

sniffer = false
web_port = 0
log_level = "info"

ports = [
  "${PUBLIC_PORT}=${TARGET_HOST}:${TARGET_PORT}"
]
EOF
chmod 600 /etc/backhaul/server.toml

info "Creating persistent systemd service"
cat > /etc/systemd/system/backhaul-server.service <<'EOF'
[Unit]
Description=Backhaul WSSMux Server - Iran
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/backhaul -c /etc/backhaul/server.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

if ufw status 2>/dev/null | grep -q '^Status: active'; then
  read -r -p "UFW is active. Open ${CONTROL_PORT}/tcp and ${PUBLIC_PORT}/tcp? [Y/n]: " OPEN_UFW
  OPEN_UFW="${OPEN_UFW:-Y}"
  if [[ "$OPEN_UFW" =~ ^[Yy]$ ]]; then
    ufw allow "${CONTROL_PORT}/tcp"
    ufw allow "${PUBLIC_PORT}/tcp"
  fi
fi

systemctl daemon-reload
systemctl enable --now backhaul-server.service
sleep 2

info "Final status"
systemctl --no-pager --full status backhaul-server.service || true
echo
ss -lntp | grep -E ":(${CONTROL_PORT}|${PUBLIC_PORT})[[:space:]]" || true

echo
echo "============================================================"
echo "Backhaul Server installed successfully."
echo "Iran IP        : ${IRAN_IP}"
echo "Control port   : ${CONTROL_PORT}"
echo "Public port    : ${PUBLIC_PORT}"
echo "Foreign target : ${TARGET_HOST}:${TARGET_PORT}"
echo
echo "TOKEN (use this on the foreign server):"
echo "${TOKEN}"
echo
echo "Token file: /etc/backhaul/token"
echo "Note: public port ${PUBLIC_PORT} may not appear in ss until a Client connects."
echo "============================================================"
