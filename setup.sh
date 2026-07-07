#!/bin/bash
#
# WireGuard full auto-setup for any Ubuntu/Debian VPS.
# Sets up a WireGuard SERVER and generates one client config (+ QR).
#
# Usage:
#   sudo bash setup.sh
#
# Optional env overrides:
#   WG_PORT=51820  WG_NET=10.8.0  WG_CLIENTS=1  DNS=1.1.1.1  bash setup.sh
#

set -euo pipefail

# ---- must be root ----------------------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root:  sudo bash setup.sh" >&2
  exit 1
fi

# ---- config (override via env) --------------------------------------------
WG_PORT="${WG_PORT:-51820}"          # UDP port WireGuard listens on
WG_NET="${WG_NET:-10.8.0}"           # VPN subnet prefix -> 10.8.0.0/24
WG_IF="${WG_IF:-wg0}"                # WireGuard interface name
DNS="${DNS:-1.1.1.1}"                # DNS pushed to clients
WG_CLIENTS="${WG_CLIENTS:-0}"        # pre-create clients in this script (0 = let the API do it)
API_PROFILES="${API_PROFILES:-100}"  # profiles the wareguard_api creates after it boots
WG_DIR="/etc/wireguard"
# client configs live in /etc/wireguard as client-<ip>.conf so the wareguard_api
# (single-profile / inactive-profile / new_client) reads/writes the SAME files.
CLIENT_OUT="${CLIENT_OUT:-$WG_DIR}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ---- fresh clean: wipe any previous WireGuard state ------------------------
echo "==> Cleaning previous WireGuard install..."
systemctl stop "wg-quick@${WG_IF}" 2>/dev/null || true
systemctl disable "wg-quick@${WG_IF}" 2>/dev/null || true
wg-quick down "${WG_IF}" 2>/dev/null || true
apt-get purge -y wireguard wireguard-tools 2>/dev/null || true
rm -rf "$WG_DIR"
rm -f /root/wg-clients/*.conf 2>/dev/null || true

echo "==> Installing packages..."
apt update -y
apt install -y wireguard wireguard-tools qrencode iptables curl

# ---- detect public IP + default NIC ---------------------------------------
PUB_IP="$(curl -fsS https://api.ipify.org || true)"
[ -z "$PUB_IP" ] && PUB_IP="$(curl -fsS ifconfig.me || true)"
if [ -z "$PUB_IP" ]; then
  echo "Could not auto-detect public IP. Set it manually:" >&2
  echo "  PUB_IP=1.2.3.4 bash setup.sh" >&2
  PUB_IP="${PUB_IP:-YOUR_SERVER_IP}"
fi
# override allowed
PUB_IP="${PUB_IP_OVERRIDE:-$PUB_IP}"

NIC="$(ip -4 route ls | awk '/default/ {print $5; exit}')"
[ -z "$NIC" ] && NIC="eth0"
echo "==> Public IP: $PUB_IP   Outbound NIC: $NIC"

# ---- enable IP forwarding (persistent) ------------------------------------
echo "==> Enabling IPv4 forwarding..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf; then
  echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
fi
sysctl -w net.ipv4.conf.all.src_valid_mark=1 >/dev/null || true
if grep -q '^#\?net.ipv4.conf.all.src_valid_mark=' /etc/sysctl.conf; then
  sed -i 's/^#\?net\.ipv4\.conf\.all\.src_valid_mark=.*/net.ipv4.conf.all.src_valid_mark=1/' /etc/sysctl.conf
else
  echo 'net.ipv4.conf.all.src_valid_mark=1' >> /etc/sysctl.conf
fi

# ---- server keys ----------------------------------------------------------
# NOTE: key filenames match wareguard_api (server-private.key / server-public.key)
# so /new_client can read the server pubkey it wrote.
mkdir -p "$WG_DIR"
umask 077
if [ ! -f "$WG_DIR/server-private.key" ]; then
  echo "==> Generating server keys..."
  wg genkey | tee "$WG_DIR/server-private.key" | wg pubkey > "$WG_DIR/server-public.key"
fi
SRV_PRIV="$(cat "$WG_DIR/server-private.key")"
SRV_PUB="$(cat "$WG_DIR/server-public.key")"

# ---- write server config --------------------------------------------------
# Layout mirrors wareguard_api NewServerCreate() exactly so API can append peers.
echo "==> Writing $WG_DIR/$WG_IF.conf ..."
cat > "$WG_DIR/$WG_IF.conf" <<EOF
[Interface]
Address = ${WG_NET}.1/24
PrivateKey = ${SRV_PRIV}
ListenPort = ${WG_PORT}
PostUp = iptables -A FORWARD -i ${WG_IF} -o ${NIC} -j ACCEPT
PostUp = iptables -A FORWARD -i ${NIC} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PostUp = iptables -t nat -A POSTROUTING -s ${WG_NET}.0/24 -o ${NIC} -j MASQUERADE
PreDown = iptables -D FORWARD -i ${WG_IF} -o ${NIC} -j ACCEPT
PreDown = iptables -D FORWARD -i ${NIC} -o ${WG_IF} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
PreDown = iptables -t nat -D POSTROUTING -s ${WG_NET}.0/24 -o ${NIC} -j MASQUERADE
EOF

# ---- generate clients -----------------------------------------------------
mkdir -p "$CLIENT_OUT"
echo "==> Creating $WG_CLIENTS client(s)..."
# Peer + client-conf layout mirrors wareguard_api NewClientCreate() exactly:
#   - server peer block: no PresharedKey, AllowedIPs = <ip>/32
#   - client file: /etc/wireguard/client-<ip>.conf
# so API /new_client keeps adding peers and /single-profile can read them.
for i in $(seq 1 "$WG_CLIENTS"); do
  CIP="${WG_NET}.$((i+1))"                 # 10.8.0.2, .3, ...
  CPRIV="$(wg genkey)"
  CPUB="$(echo "$CPRIV" | wg pubkey)"

  # add peer to server config
  cat >> "$WG_DIR/$WG_IF.conf" <<EOF

[Peer]
PublicKey = ${CPUB}
AllowedIPs = ${CIP}/32
EOF

  # write client config (API naming: client-<ip>.conf)
  CFILE="$CLIENT_OUT/client-${CIP}.conf"
  cat > "$CFILE" <<EOF
[Interface]
PrivateKey = ${CPRIV}
Address = ${CIP}/32
DNS = ${DNS}

[Peer]
PublicKey = ${SRV_PUB}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  echo "   -> $CFILE"
done

# ---- firewall (UFW) -------------------------------------------------------
echo "==> Configuring UFW..."
apt install -y ufw
if grep -q '^DEFAULT_FORWARD_POLICY=' /etc/default/ufw; then
  sed -i 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw
else
  echo 'DEFAULT_FORWARD_POLICY="ACCEPT"' >> /etc/default/ufw
fi
ufw allow OpenSSH || true
ufw allow 22/tcp || true
ufw allow "${WG_PORT}"/udp || true    # WireGuard
ufw allow 80/tcp || true              # Nginx HTTP
ufw allow 443/tcp || true             # Nginx HTTPS
ufw route allow in on "${WG_IF}" out on "${NIC}" || true
ufw route allow in on "${NIC}" out on "${WG_IF}" || true
echo "==> Enabling UFW..."
ufw --force enable
ufw reload || true

# ---- start service --------------------------------------------------------
echo "==> Starting WireGuard..."
systemctl enable "wg-quick@${WG_IF}"
# restart cleanly in case of re-run
systemctl restart "wg-quick@${WG_IF}"

echo
echo "============================================================"
echo " WireGuard SERVER up on ${PUB_IP}:${WG_PORT}/udp"
echo " Server pubkey: ${SRV_PUB}"
echo " Client configs: ${CLIENT_OUT}/"
echo "============================================================"
wg show "${WG_IF}" || true

# ---- print QR for first client (scan with phone app) ----------------------
FIRST_CLIENT="$CLIENT_OUT/client-${WG_NET}.2.conf"
if [ -f "$FIRST_CLIENT" ]; then
  echo
  echo "Scan this QR in the WireGuard phone app (${WG_NET}.2):"
  qrencode -t ansiutf8 < "$FIRST_CLIENT" || true
fi

# ===========================================================================
#  APP DEPLOY: Node.js + PM2 + Nginx + clone & run wareguard_api
# ===========================================================================
APP_REPO="${APP_REPO:-https://github.com/tanvirmahamudshakil/wareguard_api.git}"
APP_DIR="${APP_DIR:-/root/wareguard_api}"
APP_ENTRY="${APP_ENTRY:-server.mjs}"     # pm2 entry file
APP_PORT="${APP_PORT:-3002}"             # port app listens on (nginx proxies here)

echo
echo "==> Installing Node.js (current) ..."
curl -fsSL https://deb.nodesource.com/setup_current.x | bash -
apt install -y nodejs git nginx
node -v
npm -v

echo "==> Installing PM2 globally ..."
npm i -g pm2

echo "==> Cloning app repo ..."
if [ -d "$APP_DIR/.git" ]; then
  git -C "$APP_DIR" pull --ff-only || true
else
  rm -rf "$APP_DIR"
  git clone "$APP_REPO" "$APP_DIR"
fi

echo "==> npm install ..."
cd "$APP_DIR"
npm install

echo "==> Starting app with PM2 ..."
pm2 delete "$APP_ENTRY" 2>/dev/null || true
pm2 start "$APP_ENTRY"
pm2 save
# make pm2 come back after reboot
pm2 startup systemd -u root --hp /root >/dev/null 2>&1 || true

echo "==> Configuring Nginx reverse proxy -> localhost:${APP_PORT} ..."
cat > /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_http_version 1.1;
        proxy_cache_bypass \$http_upgrade;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_pass http://localhost:${APP_PORT};
    }
}
EOF

nginx -t
systemctl restart nginx

if command -v ufw >/dev/null 2>&1; then
  ufw allow 'Nginx Full' || true
fi

# ---- create client profiles via the API -----------------------------------
# wait for the API to be reachable, then ask it to create ${API_PROFILES} clients.
if [ "${API_PROFILES}" -gt 0 ]; then
  echo "==> Waiting for API on localhost:${APP_PORT} ..."
  for _ in $(seq 1 30); do
    curl -fsS -o /dev/null "http://localhost:${APP_PORT}/health" -H "ab: d2lyZWd1YXJkLWFi" && break
    sleep 1
  done

  echo "==> Creating ${API_PROFILES} client profiles via API ..."
  curl -fsS "http://localhost:${APP_PORT}/new_client?profile=${API_PROFILES}" \
       -H "ab: d2lyZWd1YXJkLWFi" || echo "   (API profile creation failed — check 'pm2 logs')"
  echo
fi

echo
echo "============================================================"
echo " App '$APP_ENTRY' running via PM2 (port ${APP_PORT})"
echo " Nginx proxying http://${PUB_IP}/  ->  localhost:${APP_PORT}"
echo " Created ${API_PROFILES} client profiles: ${WG_DIR}/client-<ip>.conf"
echo "============================================================"
pm2 list

echo
echo "Done. WireGuard + Node app both up. Client configs: ${CLIENT_OUT}/client-<ip>.conf"
