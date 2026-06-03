#!/bin/bash
# set -euo pipefail supprimé — évite arrêt sur erreurs non critiques
set -uo pipefail

# ==========================================================
# SlowDNS DNSTT Server - Version finale consolidée
# Compatible Debian 11/12 & Ubuntu 20.04+
# Backend : SSH / V2Ray / MIX
# Sécurisé via nftables (sans casser UDP Request)
# ==========================================================

SLOWDNS_DIR="/etc/slowdns"
SLOWDNS_BIN="/usr/local/bin/dnstt-server"
PORT=5300
CONFIG_FILE="$SLOWDNS_DIR/ns.conf"
SERVER_KEY="$SLOWDNS_DIR/server.key"
SERVER_PUB="$SLOWDNS_DIR/server.pub"
ENV_FILE="$SLOWDNS_DIR/slowdns.env"
BACKEND_CONF="$SLOWDNS_DIR/backend.conf"

CF_API_TOKEN="7mn4LKcZARvdbLlCVFTtaX7LGM2xsnyjHkiTAt37"
CF_ZONE_ID="7debbb8ea4946898a889c4b5745ab7eb"

PUB_IFACE="eth0"   # ⚠️ interface publique VPS

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# ===================== CHECK ROOT =====================
if [[ "$EUID" -ne 0 ]]; then
  echo "Ce script doit être exécuté en root" >&2
  exit 1
fi

mkdir -p "$SLOWDNS_DIR"

# ===================== DNS LOCAL =====================
log "Configuration DNS système..."
systemctl disable --now systemd-resolved.service >/dev/null 2>&1 || true
chattr -i /etc/resolv.conf 2>/dev/null || true

cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1
options attempts:1
EOF

chmod 644 /etc/resolv.conf

# ===================== DEPENDANCES =====================
log "Installation des dépendances..."
export DEBIAN_FRONTEND=noninteractive
apt update -y
apt install -y iptables curl tcpdump jq python3 python3-venv python3-pip iproute2

# ===================== PYTHON VENV =====================
if [[ ! -d "$SLOWDNS_DIR/venv" ]]; then
  python3 -m venv "$SLOWDNS_DIR/venv"
fi

source "$SLOWDNS_DIR/venv/bin/activate"
pip install --upgrade pip >/dev/null
pip install cloudflare >/dev/null || log "cloudflare lib non critique"

# ===================== DNSTT =====================
if [[ ! -x "$SLOWDNS_BIN" ]]; then
  log "Téléchargement DNSTT server..."
  curl -fsSL https://dnstt-server-client.s3.amazonaws.com/dnstt-server-linux-amd64 -o "$SLOWDNS_BIN"
  chmod +x "$SLOWDNS_BIN"
fi

# ===================== BACKEND =====================
choose_backend() {
  echo
  echo "Choix du backend SlowDNS"
  echo "1) SSH"
  echo "2) V2Ray"
  echo "3) WS"
  read -rp "Sélection [1-3] : " c

  case "$c" in
    1) BACKEND_MODE="ssh" ;;
    2) BACKEND_MODE="v2ray" ;;
    3) BACKEND_MODE="WS" ;;
    *) echo "Choix invalide"; exit 1 ;;
  esac

  echo "BACKEND_MODE=$BACKEND_MODE" > "$BACKEND_CONF"
  log "Backend sélectionné : $BACKEND_MODE"
}

# ===================== NS =====================
read -rp "Mode NS [auto/man] : " MODE
MODE=${MODE,,}

generate_ns_auto() {
  DOMAIN="kingom.ggff.net"
  VPS_IP=$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")

  SUB="$(date +%s | sha256sum | cut -c1-6)"
  FQDN_A="vpn-$SUB.$DOMAIN"
  NS="ns-$SUB.$DOMAIN"

  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"A\",\"name\":\"$FQDN_A\",\"content\":\"$VPS_IP\",\"ttl\":120,\"proxied\":false}" >/dev/null

  curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json" \
    --data "{\"type\":\"NS\",\"name\":\"$NS\",\"content\":\"$FQDN_A\",\"ttl\":120}" >/dev/null

  echo -e "NS=$NS\nENV_MODE=auto" > "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "$NS"
}

if [[ "$MODE" == "auto" ]]; then
  [[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
  [[ "${ENV_MODE:-}" == "auto" && -n "${NS:-}" ]] || NS=$(generate_ns_auto)
elif [[ "$MODE" == "man" ]]; then
  read -rp "Entrez NS : " NS
  echo -e "NS=$NS\nENV_MODE=man" > "$ENV_FILE"
else
  echo "Mode invalide"; exit 1
fi

choose_backend

echo "$NS" > "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

# ===================== KEYS =====================
cat > "$SERVER_KEY" <<'EOF'
4ab3af05fc004cb69d50c89de2cd5d138be1c397a55788b8867088e801f7fcaa
EOF

cat > "$SERVER_PUB" <<'EOF'
2cb39d63928451bd67f5954ffa5ac16c8d903562a10c4b21756de4f1a82d581c
EOF

chmod 600 "$SERVER_KEY"
chmod 644 "$SERVER_PUB"

# ===================== SYSCTL =====================
log "Optimisation réseau kernel..."
cat > /etc/sysctl.d/99-slowdns.conf <<EOF
net.ipv4.ip_forward=1
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.netdev_max_backlog=60000
net.core.somaxconn=4096
EOF

sysctl --system >/dev/null

# ===================== START SCRIPT =====================
cat > /usr/local/bin/slowdns-start.sh <<'STARTEOF'
#!/bin/bash
# Pas de set -e : on gère les erreurs manuellement pour éviter les arrêts inattendus

DIR="/etc/slowdns"
BIN="/usr/local/bin/dnstt-server"
LOG="/var/log/slowdns.log"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] slowdns-start.sh démarré" >> "$LOG"

# Vérifier les fichiers essentiels
if [[ ! -x "$BIN" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : $BIN introuvable ou non exécutable" >> "$LOG"
    exit 1
fi

if [[ ! -f "$DIR/server.key" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : $DIR/server.key introuvable" >> "$LOG"
    exit 1
fi

if [[ ! -f "$DIR/ns.conf" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : $DIR/ns.conf introuvable" >> "$LOG"
    exit 1
fi

NS=$(cat "$DIR/ns.conf" | tr -d '\n\r ')
if [[ -z "$NS" ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERREUR : ns.conf est vide" >> "$LOG"
    exit 1
fi

# Lire le backend
BACKEND_MODE="ssh"
[[ -f "$DIR/backend.conf" ]] && source "$DIR/backend.conf" 2>/dev/null || true

case "$BACKEND_MODE" in
  ssh)   TARGET="127.0.0.1:109" ;;
  v2ray) TARGET="127.0.0.1:5401" ;;
  WS)    TARGET="127.0.0.1:80" ;;
  *)     TARGET="127.0.0.1:109" ;;
esac

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Démarrage dnstt-server → NS=$NS TARGET=$TARGET" >> "$LOG"

# Lancer dnstt-server — exec remplace ce process (systemd gère le restart)
exec "$BIN" -udp :5300 \
  -privkey-file "$DIR/server.key" \
  "$NS" "$TARGET"
STARTEOF

chmod +x /usr/local/bin/slowdns-start.sh

# ===================== SYSTEMD =====================
cat > /etc/systemd/system/slowdns.service <<'EOF'
[Unit]
Description=SlowDNS DNSTT Server
After=network-online.target
Wants=network-online.target
# Redémarrer même après trop d'échecs
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/bin/slowdns-start.sh
# Toujours redémarrer — même si exit code non nul
Restart=always
RestartSec=5
# Pas de limite de restart (évite l'état "failed" définitif)
StartLimitBurst=0
LimitNOFILE=1048576
# Tuer proprement le process dnstt-server
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=10
StandardOutput=append:/var/log/slowdns.log
StandardError=append:/var/log/slowdns.log

[Install]
WantedBy=multi-user.target
EOF

# ===================== IPTABLES SLOWDNS (PROPRE) =====================

# Autoriser SlowDNS local
iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p udp --dport 5300 -j ACCEPT

iptables -C INPUT -p tcp --dport 5300 -j ACCEPT 2>/dev/null || \
iptables -A INPUT -p tcp --dport 5300 -j ACCEPT


# Nettoyage ciblé
iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true
iptables -t nat -D PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true


# 🔥 Redirection UNIQUEMENT trafic entrant client
iptables -t nat -I PREROUTING 1 -p udp --dport 53 -j REDIRECT --to-ports 5300
iptables -t nat -I PREROUTING 1 -p tcp --dport 53 -j REDIRECT --to-ports 5300


netfilter-persistent save
systemctl enable slowdns
systemctl restart slowdns

log "✅ SlowDNS installé, sécurisé et compatible UDP Request"
