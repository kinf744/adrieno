#!/bin/bash
# ================================================================
# Xray Installer v2 — Architecture HAProxy (routeur) + Nginx
#
# Port 8880 NTLS : HAProxy → HTTP/1.1 (GET/POST) → Nginx :8881 → Xray
#                         → HTTP/2 (PRI)        → routeur gRPC → Xray direct
#                         → TCP                 → Xray (VLESS/Trojan)
# Port 8443 TLS  : HAProxy → ALPN h2            → routeur gRPC → Xray direct
#                         → ALPN http/1.1       → Nginx :8444 → Xray
#                         → sans ALPN (TCP)     → Xray (VLESS/Trojan)
# Routeur gRPC (127.0.0.1:9898) : path_beg /...-grpc → Xray direct
#                                 default → Nginx (fallback XHTTP h2)
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "  ${CYAN}[•]${NC} $1"; }
ok()    { echo -e "  ${GREEN}[✓]${NC} $1"; }
err()   { echo -e "  ${RED}[✗]${NC} $1"; }

XRAY_VER="26.1.23"
DOMAIN=""

# ========== DOMAINE ==========
read -rp "Entrez votre nom de domaine (ex: monsite.com) : " DOMAIN
[[ -z "$DOMAIN" ]] && { err "Domaine requis."; exit 1; }

mkdir -p /etc/xray
echo "$DOMAIN" > /etc/xray/domain

EMAIL="adrienkiaje@gmail.com"

# ========== PORTS XRAY (127.0.0.1) ==========
# NTLS
PORT_VMESS_WS_NTLS=23457
PORT_VLESS_WS_NTLS=14017
PORT_TROJAN_WS_NTLS=13003
PORT_SHADOW_WS_NTLS=13004
PORT_VLESS_TCP_NTLS=14019
PORT_TROJAN_TCP_NTLS=13012
# TLS
PORT_VMESS_WS_TLS=23456
PORT_VLESS_WS_TLS=14016
PORT_TROJAN_WS_TLS=13001
PORT_SHADOW_WS_TLS=13005
PORT_VLESS_XHTTP_TLS=14030
PORT_TROJAN_XHTTP_TLS=13030
PORT_VLESS_HTTPUPGRADE_TLS=14040
PORT_VMESS_GRPC_TLS=31234
PORT_VLESS_GRPC_TLS=24456
PORT_TROJAN_GRPC_TLS=13002
PORT_SHADOW_GRPC_TLS=13006
PORT_VLESS_TCP_TLS=14018
PORT_TROJAN_TCP_TLS=13011
PORT_API=10085

# ========== DÉPENDANCES ==========
info "Installation des dépendances..."
apt update -y
apt install -y iptables nginx haproxy iptables-persistent curl socat xz-utils wget \
  apt-transport-https gnupg dnsutils lsb-release cron bash-completion ntpdate chrony \
  unzip jq ca-certificates libcap2-bin lsof
ok "Dépendances installées."

# ========== IPTABLES ==========
info "Configuration iptables..."
for port in 80 81 8880 8443; do
  iptables -C INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport $port -j ACCEPT
done
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
netfilter-persistent save
ok "Ports ouverts : 80, 81, 8880, 8443"

# ========== XRAY v26.1.23 ==========
info "Installation Xray v${XRAY_VER}..."
XRAY_LINK="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/xray-linux-64.zip"

mkdir -p /tmp/xray_install && cd /tmp/xray_install
curl -L -o xray.zip "$XRAY_LINK" || {
  err "Échec téléchargement Xray v${XRAY_VER}. Utilisation de la dernière version..."
  latest=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | grep tag_name | cut -d'"' -f4 | sed 's/v//')
  XRAY_VER="$latest"
  curl -L -o xray.zip "https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VER}/xray-linux-64.zip"
}

unzip -o xray.zip
mv -f xray /usr/local/bin/xray
chmod +x /usr/local/bin/xray
setcap 'cap_net_bind_service=+ep' /usr/local/bin/xray 2>/dev/null || true
ok "Xray v${XRAY_VER} installé."

mkdir -p /var/log/xray /etc/xray
touch /var/log/xray/access.log /var/log/xray/error.log
chmod 644 /var/log/xray/access.log /var/log/xray/error.log

# ========== CERTIFICAT TLS ==========
ACME_CERT="/etc/xray/xray.crt"
ACME_KEY="/etc/xray/xray.key"
GENERATE_TLS=false

if [[ -f "$ACME_CERT" && -f "$ACME_KEY" ]]; then
  if openssl x509 -checkend 86400 -noout -in "$ACME_CERT" >/dev/null 2>&1; then
    ok "Certificat TLS valide trouvé."
  else
    info "Certificat expiré — régénération..."
    GENERATE_TLS=true
  fi
else
  info "Aucun certificat — génération..."
  GENERATE_TLS=true
fi

if [[ "$GENERATE_TLS" == true ]]; then
  # ACME
  if [ ! -f ~/.acme.sh/acme.sh ]; then
    cd /root/
    wget -q https://raw.githubusercontent.com/NevermoreSSH/hop/main/acme.sh
    bash acme.sh --install && rm acme.sh
  fi

  cd ~/.acme.sh
  bash acme.sh --register-account -m "$EMAIL" || true

  WEBROOT="/var/www/html"
  mkdir -p "${WEBROOT}/.well-known/acme-challenge"

  cat > /etc/nginx/conf.d/acme-challenge.conf << ACMEOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root ${WEBROOT};
    location /.well-known/acme-challenge/ { allow all; }
}
ACMEOF

  systemctl start nginx 2>/dev/null || nginx -t && systemctl reload nginx 2>/dev/null || true

  for cert_dir in "${HOME}/.acme.sh/${DOMAIN}" "${HOME}/.acme.sh/${DOMAIN}_ecc"; do
    [[ -d "$cert_dir" && ! -f "$cert_dir/${DOMAIN}.key" ]] && rm -rf "$cert_dir"
  done

  if ! bash acme.sh --list 2>/dev/null | grep -q "$DOMAIN"; then
    bash acme.sh --issue --webroot "$WEBROOT" -d "$DOMAIN" --keylength ec-256 || true
  fi

  bash acme.sh --installcert -d "$DOMAIN" \
    --fullchainpath "$ACME_CERT" \
    --keypath "$ACME_KEY" \
    --ecc \
    --reloadcmd "systemctl restart xray haproxy nginx"

  rm -f /etc/nginx/conf.d/acme-challenge.conf
  nginx -t && systemctl reload nginx || true

  if [[ ! -f "$ACME_CERT" || ! -f "$ACME_KEY" ]]; then
    err "Certificat TLS non généré."
    exit 1
  fi
  ok "Certificat TLS généré."
fi

# Combiner cert+key pour HAProxy (format PEM)
cat "$ACME_CERT" "$ACME_KEY" > /etc/xray/xray.pem
chmod 600 /etc/xray/xray.pem

# ========== USERS.JSON ==========
cat > /etc/xray/users.json << 'USERSEOF'
{
  "vmess": [],
  "vless": [],
  "trojan": [],
  "shadow": []
}
USERSEOF

# ========== CONFIG XRAY ==========
info "Génération config Xray..."

# Fonction helper pour clients vides
cli_vmess='{"clients":[]}'
cli_vless='{"decryption":"none","clients":[]}'
cli_trojan='{"clients":[]}'
cli_shadow='{"clients":[],"network":"tcp,udp"}'

# WS settings helper
ws_cfg() { local p="$1"; echo "{\"network\":\"ws\",\"wsSettings\":{\"path\":\"$p\",\"host\":\"$DOMAIN\"}}"; }
ws_cfg_nohost() { local p="$1"; echo "{\"network\":\"ws\",\"wsSettings\":{\"path\":\"$p\"}}"; }
xhttp_cfg() { local p="$1"; echo "{\"network\":\"xhttp\",\"xhttpSettings\":{\"path\":\"$p\"}}"; }
hup_cfg() { local p="$1"; echo "{\"network\":\"httpupgrade\",\"httpupgradeSettings\":{\"path\":\"$p\"}}"; }
grpc_cfg() { local s="$1"; echo "{\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"$s\"}}"; }
tcp_cfg='{"network":"tcp"}'
shad_ws_cfg() { local p="$1"; echo "{\"network\":\"ws\",\"wsSettings\":{\"path\":\"$p\"}}"; }
shad_grpc_cfg() { local s="$1"; echo "{\"network\":\"grpc\",\"grpcSettings\":{\"serviceName\":\"$s\"}}"; }

# Build inbounds JSON
build_inbounds() {
cat << INBOUNDS
[
  { "tag": "api", "listen": "127.0.0.1", "port": $PORT_API, "protocol": "dokodemo-door", "settings": { "address": "127.0.0.1" } },

  { "tag": "vmess-ws-ntls", "listen": "127.0.0.1", "port": $PORT_VMESS_WS_NTLS, "protocol": "vmess", "settings": $cli_vmess, "streamSettings": $(ws_cfg_nohost "/vmess") },
  { "tag": "vless-ws-ntls", "listen": "127.0.0.1", "port": $PORT_VLESS_WS_NTLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $(ws_cfg_nohost "/vless") },
  { "tag": "trojan-ws-ntls", "listen": "127.0.0.1", "port": $PORT_TROJAN_WS_NTLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $(ws_cfg_nohost "/trojan") },
  { "tag": "shadow-ws-ntls", "listen": "127.0.0.1", "port": $PORT_SHADOW_WS_NTLS, "protocol": "shadowsocks", "settings": $cli_shadow, "streamSettings": $(shad_ws_cfg "/shadow") },

  { "tag": "vless-tcp-ntls", "listen": "127.0.0.1", "port": $PORT_VLESS_TCP_NTLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $tcp_cfg },
  { "tag": "trojan-tcp-ntls", "listen": "127.0.0.1", "port": $PORT_TROJAN_TCP_NTLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $tcp_cfg },

  { "tag": "vmess-ws-tls", "listen": "127.0.0.1", "port": $PORT_VMESS_WS_TLS, "protocol": "vmess", "settings": $cli_vmess, "streamSettings": $(ws_cfg "/vmess") },
  { "tag": "vless-ws-tls", "listen": "127.0.0.1", "port": $PORT_VLESS_WS_TLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $(ws_cfg "/vless") },
  { "tag": "trojan-ws-tls", "listen": "127.0.0.1", "port": $PORT_TROJAN_WS_TLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $(ws_cfg "/trojan") },
  { "tag": "shadow-ws-tls", "listen": "127.0.0.1", "port": $PORT_SHADOW_WS_TLS, "protocol": "shadowsocks", "settings": $cli_shadow, "streamSettings": $(ws_cfg "/shadow") },

  { "tag": "vless-xhttp-tls", "listen": "127.0.0.1", "port": $PORT_VLESS_XHTTP_TLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $(xhttp_cfg "/vless-xhttp") },
  { "tag": "trojan-xhttp-tls", "listen": "127.0.0.1", "port": $PORT_TROJAN_XHTTP_TLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $(xhttp_cfg "/trojan-xhttp") },

  { "tag": "vless-httpupgrade-tls", "listen": "127.0.0.1", "port": $PORT_VLESS_HTTPUPGRADE_TLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $(hup_cfg "/vless-hupgrade") },

  { "tag": "vmess-grpc-tls", "listen": "127.0.0.1", "port": $PORT_VMESS_GRPC_TLS, "protocol": "vmess", "settings": $cli_vmess, "streamSettings": $(grpc_cfg "vmess-grpc") },
  { "tag": "vless-grpc-tls", "listen": "127.0.0.1", "port": $PORT_VLESS_GRPC_TLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $(grpc_cfg "vless-grpc") },
  { "tag": "trojan-grpc-tls", "listen": "127.0.0.1", "port": $PORT_TROJAN_GRPC_TLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $(grpc_cfg "trojan-grpc") },
  { "tag": "shadow-grpc-tls", "listen": "127.0.0.1", "port": $PORT_SHADOW_GRPC_TLS, "protocol": "shadowsocks", "settings": $cli_shadow, "streamSettings": $(shad_grpc_cfg "shadow-grpc") },

  { "tag": "vless-tcp-tls", "listen": "127.0.0.1", "port": $PORT_VLESS_TCP_TLS, "protocol": "vless", "settings": $cli_vless, "streamSettings": $tcp_cfg },
  { "tag": "trojan-tcp-tls", "listen": "127.0.0.1", "port": $PORT_TROJAN_TCP_TLS, "protocol": "trojan", "settings": $cli_trojan, "streamSettings": $tcp_cfg }
]
INBOUNDS
}

cat > /etc/xray/config.json << CONFIGEOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": $(build_inbounds),
  "outbounds": [
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "blocked" },
    { "protocol": "freedom", "tag": "api" }
  ],
  "routing": {
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "ip": ["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","::1/128","fc00::/7","fe80::/10"], "outboundTag": "blocked" },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked" }
    ]
  },
  "stats": {},
  "api": { "services": ["StatsService"], "tag": "api" },
  "policy": {
    "levels": { "0": { "statsUserDownlink": true, "statsUserUplink": true } },
    "system": { "statsInboundUplink": true, "statsInboundDownlink": true, "statsOutboundUplink": true, "statsOutboundDownlink": true }
  }
}
CONFIGEOF
ok "Config Xray générée."

# ========== SERVICE SYSTEMD XRAY ==========
cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray Service
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray -config /etc/xray/config.json
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SVCEOF

# ========== NGINX CONFIG ==========
info "Configuration Nginx..."

# NGINX :8881 (NTLS backend, reçoit de HAProxy)
cat > /etc/nginx/conf.d/xray-ntls.conf << 'NGINXNTLS'
server {
    listen 127.0.0.1:8881;
    server_name _;
    root /var/www/html;

    location /vmess  { proxy_pass http://127.0.0.1:23457; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /vless  { proxy_pass http://127.0.0.1:14017; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /trojan { proxy_pass http://127.0.0.1:13003; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /shadow { proxy_pass http://127.0.0.1:13004; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
NGINXNTLS

# NGINX :8444 (TLS backend, reçoit de HAProxy, TLS déjà terminé)
cat > /etc/nginx/conf.d/xray-tls.conf << 'NGINXTLS'
server {
    listen 127.0.0.1:8444;
    server_name _;
    root /var/www/html;

    location /vmess  { proxy_pass http://127.0.0.1:23456; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /vless  { proxy_pass http://127.0.0.1:14016; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /trojan { proxy_pass http://127.0.0.1:13001; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /shadow { proxy_pass http://127.0.0.1:13005; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }

    location /vless-xhttp  { proxy_pass http://127.0.0.1:14030; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
    location /trojan-xhttp { proxy_pass http://127.0.0.1:13030; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }

    location /vless-hupgrade { proxy_pass http://127.0.0.1:14040; proxy_http_version 1.1; proxy_set_header Upgrade $http_upgrade; proxy_set_header Connection "upgrade"; proxy_set_header Host $host; proxy_set_header X-Real-IP $remote_addr; }
}
NGINXTLS

# Default server sur 81 (pour le panel)
cat > /etc/nginx/sites-enabled/default << NGINXDEF
server {
    listen 81 default_server;
    listen [::]:81 default_server;
    server_name _;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
NGINXDEF

# Override restart
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'NGINXOVR'
[Service]
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
NGINXOVR

ok "Nginx configuré."

# ========== HAPROXY CONFIG ==========
info "Configuration HAProxy..."

cat > /etc/haproxy/haproxy.cfg << 'HAPEOF'
global
    daemon
    maxconn 4096
    log /dev/log local0
    # Mode HTTP compatible avec HTTP/2
    tune.h2.max-concurrent-streams 128

defaults
    mode tcp
    log global
    option tcplog
    retries 3
    timeout connect 5s
    timeout client 30s
    timeout server 30s

# ── NTLS (8880) ──────────────────────────────────────
frontend ntls_frontend
    bind :8880
    mode tcp
    tcp-request inspect-delay 3s
    tcp-request content accept if { req.len ge 5 }
    acl is_http  req.payload(0,5) -m bin 474554202f
    acl is_post req.payload(0,4) -m bin 504f5354
    acl is_h2   req.payload(0,3) -m bin 505249
    acl is_vless req.payload(0,1) -m bin 00
    use_backend grpc_router if is_h2
    use_backend nginx_ntls if is_http or is_post
    use_backend xray_trojan_ntls if !is_vless
    default_backend xray_vless_ntls

backend nginx_ntls
    mode tcp
    server nginx_ntls 127.0.0.1:8881

backend xray_vless_ntls
    mode tcp
    server vless_tcp_ntls 127.0.0.1:14019

backend xray_trojan_ntls
    mode tcp
    server trojan_tcp_ntls 127.0.0.1:13012

# ── TLS (8443) ────────────────────────────────────────
frontend tls_frontend
    bind :8443 ssl crt /etc/xray/xray.pem alpn h2,http/1.1
    mode tcp
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.len ge 5 }
    acl is_http req.payload(0,5) -m bin 474554202f
    acl is_post req.payload(0,4) -m bin 504f5354
    acl is_pri  req.payload(0,3) -m bin 505249
    acl is_vless req.payload(0,1) -m bin 00
    use_backend grpc_router if is_pri
    use_backend nginx_tls if is_http or is_post
    use_backend xray_trojan_tls if !is_vless
    default_backend xray_vless_tls

backend nginx_tls
    mode tcp
    server nginx_tls 127.0.0.1:8444

backend xray_vless_tls
    mode tcp
    server vless_tcp_tls 127.0.0.1:14018

backend xray_trojan_tls
    mode tcp
    server trojan_tcp_tls 127.0.0.1:13011

# ── Relais gRPC (TCP → routeur HTTP interne) ────────
backend grpc_router
    mode tcp
    server grpc_http_router 127.0.0.1:9898

# ── Routeur gRPC (interne, mode http) ───────────────
frontend grpc_http_router
    bind 127.0.0.1:9898
    mode http
    timeout http-request 5s
    use_backend xray_vmess_grpc  if { path_beg /vmess-grpc  }
    use_backend xray_vless_grpc  if { path_beg /vless-grpc  }
    use_backend xray_trojan_grpc if { path_beg /trojan-grpc }
    use_backend xray_shadow_grpc if { path_beg /shadow-grpc }
    default_backend nginx_tls_http

backend xray_vmess_grpc
    mode http
    server vmess_grpc 127.0.0.1:31234

backend xray_vless_grpc
    mode http
    server vless_grpc 127.0.0.1:24456

backend xray_trojan_grpc
    mode http
    server trojan_grpc 127.0.0.1:13002

backend xray_shadow_grpc
    mode http
    server shadow_grpc 127.0.0.1:13006

backend nginx_tls_http
    mode http
    server nginx_tls_http 127.0.0.1:8444
HAPEOF

ok "HAProxy configuré."

# ========== LOGROTATE ==========
cat > /etc/logrotate.d/xray << 'LOGEOF'
/var/log/xray/*.log {
    daily; rotate 7; compress; delaycompress; missingok; notifempty; sharedscripts
    postrotate; systemctl restart xray >/dev/null 2>&1 || true; endscript
}
LOGEOF

# ========== RÉSILIENCE ==========
info "Configuration résilience..."

# Override Nginx (network dep + restart infini)
mkdir -p /etc/systemd/system/nginx.service.d
cat > /etc/systemd/system/nginx.service.d/override.conf << 'NGXOVR'
[Unit]
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5s
NGXOVR

# Override HAProxy (identique)
mkdir -p /etc/systemd/system/haproxy.service.d
cat > /etc/systemd/system/haproxy.service.d/override.conf << 'HAPOVR'
[Unit]
After=network-online.target nss-lookup.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=5s
HAPOVR

# Backup quotidien de /etc/xray/
cat > /root/Kighmu/backup_xray.sh << 'BAKEOF'
#!/bin/bash
BACKUP_DIR="/root/backup-xray"
mkdir -p "$BACKUP_DIR"
DATE=$(date +%Y%m%d-%H%M%S)
cp /etc/xray/users.json "$BACKUP_DIR/users.json.$DATE"
cp /etc/xray/config.json "$BACKUP_DIR/config.json.$DATE"
cp /etc/xray/domain "$BACKUP_DIR/domain.$DATE" 2>/dev/null || true
find "$BACKUP_DIR" -name "users.json.*" -mtime +30 -delete 2>/dev/null
find "$BACKUP_DIR" -name "config.json.*" -mtime +30 -delete 2>/dev/null
echo "[$(date)] Backup saved: $DATE" >> /var/log/xray-backup.log
BAKEOF
chmod +x /root/Kighmu/backup_xray.sh

# Ajout watchdogs + backup au crontab (évite les doublons)
for cron_xray in $(crontab -l 2>/dev/null | grep -c "xray-watchdog.log"); do true; done
for cron_bak in $(crontab -l 2>/dev/null | grep -c "backup_xray.sh"); do true; done
if ! crontab -l 2>/dev/null | grep -q "xray-watchdog"; then
  (crontab -l 2>/dev/null; echo "*/15 * * * * systemctl is-active --quiet xray || systemctl restart xray >> /var/log/xray-watchdog.log 2>&1") | crontab -
fi
if ! crontab -l 2>/dev/null | grep -q "haproxy-watchdog"; then
  (crontab -l 2>/dev/null; echo "*/5 * * * * systemctl is-active --quiet haproxy || systemctl restart haproxy >> /var/log/haproxy-watchdog.log 2>&1") | crontab -
fi
if ! crontab -l 2>/dev/null | grep -q "nginx-watchdog"; then
  (crontab -l 2>/dev/null; echo "*/5 * * * * systemctl is-active --quiet nginx || systemctl restart nginx >> /var/log/nginx-watchdog.log 2>&1") | crontab -
fi
if ! crontab -l 2>/dev/null | grep -q "backup_xray.sh"; then
  (crontab -l 2>/dev/null; echo "0 4 * * * bash /root/Kighmu/backup_xray.sh >/dev/null 2>&1") | crontab -
fi
ok "Résilience configurée."

# ========== DÉMARRAGE ==========
info "Démarrage des services..."
systemctl daemon-reload

for svc in xray nginx haproxy; do
  systemctl enable "$svc" 2>/dev/null
  systemctl restart "$svc" 2>/dev/null
  sleep 2
  if systemctl is-active --quiet "$svc"; then
    ok "$svc → actif"
  else
    err "$svc → échec"
    journalctl -u "$svc" -n 15 --no-pager
  fi
done

# ========== VÉRIFICATION API ==========
sleep 2
info "Test API stats..."
/usr/local/bin/xray api statsquery --server=127.0.0.1:$PORT_API 2>/dev/null && ok "API stats OK" || warn "API stats indisponible"

# ========== RÉSUMÉ ==========
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║      Xray v${XRAY_VER} — Installation terminée               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Domaine : $DOMAIN"
echo ""
echo "  Port NTLS (8880) : payload GET/POST → Nginx :8881 → Xray WS"
echo "                     payload PRI*     → routeur gRPC → Xray gRPC direct / Nginx XHTTP"
echo "                     payload 0x00     → Xray (VLESS TCP)"
echo "                     payload autre    → Xray (Trojan TCP)"
echo "  Port TLS  (8443) : payload GET/POST → Nginx :8444 → Xray WS/HTTPUpgrade"
echo "                     payload PRI*     → routeur gRPC → Xray gRPC direct / Nginx XHTTP"
echo "                     payload 0x00     → Xray (VLESS TCP)"
echo "                     payload autre    → Xray (Trojan TCP)"
echo ""
echo "  Protocoles supportés :"
echo "    NTLS : VMess WS | VLESS WS/TCP | Trojan WS/TCP | Shadow WS"
echo "    TLS  : VMess WS/gRPC | VLESS WS/XHTTP/HTTPUpgrade/gRPC/TCP"
echo "           Trojan WS/XHTTP/gRPC/TCP | Shadow WS/gRPC"
echo ""
echo "  Routeur gRPC (interne 127.0.0.1:9898) :"
echo "    gRPC paths  → Xray direct (HAProxy mode http)"
echo "    Fallback h2 → Nginx (XHTTP)"
echo ""
echo "  Résilience :"
echo "    Restart infini (StartLimitIntervalSec=0) : Xray, Nginx, HAProxy"
echo "    Démarrage après réseau (network-online) : Xray, Nginx, HAProxy"
echo "    Watchdog Xray toutes les 15 min, HAProxy+Nginx toutes les 5 min (cron)"
echo "    Backup /etc/xray/ chaque jour à 4h (cron, rétention 30j)"
echo "    Logrotate Xray : daily, 7j, compressé"
echo "  API stats : 127.0.0.1:${PORT_API}"
echo "  Logs      : /var/log/xray/"
echo ""
