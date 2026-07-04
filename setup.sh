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
WG_CLIENTS="${WG_CLIENTS:-50}"       # how many client configs to create (default 50)
WG_DIR="/etc/wireguard"
CLIENT_OUT="${CLIENT_OUT:-/root/wg-clients}"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

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

# ---- server keys ----------------------------------------------------------
mkdir -p "$WG_DIR"
umask 077
if [ ! -f "$WG_DIR/server_private.key" ]; then
  echo "==> Generating server keys..."
  wg genkey | tee "$WG_DIR/server_private.key" | wg pubkey > "$WG_DIR/server_public.key"
fi
SRV_PRIV="$(cat "$WG_DIR/server_private.key")"
SRV_PUB="$(cat "$WG_DIR/server_public.key")"

# ---- write server config --------------------------------------------------
echo "==> Writing $WG_DIR/$WG_IF.conf ..."
cat > "$WG_DIR/$WG_IF.conf" <<EOF
[Interface]
Address = ${WG_NET}.1/24
ListenPort = ${WG_PORT}
PrivateKey = ${SRV_PRIV}
# NAT + forwarding rules (applied on up/down)
PostUp   = iptables -A FORWARD -i ${WG_IF} -j ACCEPT; iptables -A FORWARD -o ${WG_IF} -j ACCEPT; iptables -t nat -A POSTROUTING -o ${NIC} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IF} -j ACCEPT; iptables -D FORWARD -o ${WG_IF} -j ACCEPT; iptables -t nat -D POSTROUTING -o ${NIC} -j MASQUERADE
EOF

# ---- generate clients -----------------------------------------------------
mkdir -p "$CLIENT_OUT"
echo "==> Creating $WG_CLIENTS client(s)..."
for i in $(seq 1 "$WG_CLIENTS"); do
  CIP="${WG_NET}.$((i+1))"                 # 10.8.0.2, .3, ...
  CPRIV="$(wg genkey)"
  CPUB="$(echo "$CPRIV" | wg pubkey)"
  CPSK="$(wg genpsk)"                       # per-peer preshared key (extra security)

  # add peer to server config
  cat >> "$WG_DIR/$WG_IF.conf" <<EOF

[Peer]
# client${i}
PublicKey = ${CPUB}
PresharedKey = ${CPSK}
AllowedIPs = ${CIP}/32
EOF

  # write client config
  CFILE="$CLIENT_OUT/client${i}.conf"
  cat > "$CFILE" <<EOF
[Interface]
PrivateKey = ${CPRIV}
Address = ${CIP}/24
DNS = ${DNS}

[Peer]
PublicKey = ${SRV_PUB}
PresharedKey = ${CPSK}
Endpoint = ${PUB_IP}:${WG_PORT}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
  echo "   -> $CFILE"
done

# ---- firewall (UFW) -------------------------------------------------------
echo "==> Configuring UFW..."
apt install -y ufw
ufw allow OpenSSH || true
ufw allow 22/tcp || true
ufw allow "${WG_PORT}"/udp || true    # WireGuard
ufw allow 80/tcp || true              # Nginx HTTP
ufw allow 443/tcp || true             # Nginx HTTPS
echo "==> Enabling UFW..."
yes | ufw enable
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
if [ -f "$CLIENT_OUT/client1.conf" ]; then
  echo
  echo "Scan this QR in the WireGuard phone app (client1):"
  qrencode -t ansiutf8 < "$CLIENT_OUT/client1.conf" || true
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

echo
echo "============================================================"
echo " App '$APP_ENTRY' running via PM2 (port ${APP_PORT})"
echo " Nginx proxying http://${PUB_IP}/  ->  localhost:${APP_PORT}"
echo "============================================================"
pm2 list

echo
echo "Done. WireGuard + Node app both up. Client configs in ${CLIENT_OUT}/"
