#!/bin/bash
set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; C='\033[0;36m'; B='\033[1m'; NC='\033[0m'
info() { echo -e "  ${C}[•]${NC} $1"; }
ok()   { echo -e "  ${G}[✓]${NC} $1"; }
warn() { echo -e "  ${Y}[!]${NC} $1"; }
err()  { echo -e "  ${R}[✗]${NC} $1"; }
sep()  { echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

SLOWDNS_DIR="/etc/slowdns"
SLOWDNS_BIN="/usr/local/bin/dnstt-server"
BACKUP_DIR="/root/backup-slowdns-$(date +%Y%m%d-%H%M%S)"
SERVER_KEY="$SLOWDNS_DIR/server.key"
SERVER_PUB="$SLOWDNS_DIR/server.pub"
CONFIG_FILE="$SLOWDNS_DIR/ns.conf"
ROUTER_PY="/usr/local/bin/dns-router.py"

DOMAIN="${DOMAIN:-kingom.ggff.net}"
IP_PUBLIC="${IP_PUBLIC:-$(curl -s ipv4.icanhazip.com || echo "127.0.0.1")}"
BACKEND1_TARGET="${BACKEND1_TARGET:-127.0.0.1:109}"
BACKEND2_TARGET="${BACKEND2_TARGET:-127.0.0.1:5401}"
PORT1="${PORT1:-5353}"
PORT2="${PORT2:-5354}"
ROUTER_PORT="${ROUTER_PORT:-5300}"  # Le routeur Python écoutera sur ce port

DNSTT_PRIV_KEY="4ab3af05fc004cb69d50c89de2cd5d138be1c397a55788b8867088e801f7fcaa"
DNSTT_PUB_KEY="2cb39d63928451bd67f5954ffa5ac16c8d903562a10c4b21756de4f1a82d581c"

CF_API_TOKEN="7mn4LKcZARvdbLlCVFTtaX7LGM2xsnyjHkiTAt37"
CF_ZONE_ID="7debbb8ea4946898a889c4b5745ab7eb"

[[ "$EUID" -ne 0 ]] && { err "Exécutez en root"; exit 1; }

clear
echo -e "${C}${B}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════╗
  ║      SlowDNS v3 — Routeur Python Edition         ║
  ╚══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
sep

mkdir -p "$SLOWDNS_DIR/ns4" "$SLOWDNS_DIR/nv4" /var/log/slowdns

echo ""
echo -e "  ${B}Mode de configuration des NS :${NC}"
echo -e "  ${G}[1]${NC}  Auto — Cloudflare API"
echo -e "  ${C}[2]${NC}  Manuel — NS déjà créés"
echo ""
read -rp "  Mode [1/2] : " MODE
echo ""

if [[ "$MODE" == "1" ]]; then
  MODE="auto"
  read -rp "  Domaine principal (Entrée = $DOMAIN) : " input_domain
  DOMAIN="${input_domain:-$DOMAIN}"

  HASH1=$(printf '%s%s' "$RANDOM" "$RANDOM" | sha256sum | cut -c1-6)
  HASH2=$(printf '%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM" | sha256sum | cut -c1-6)
  while [[ "$HASH1" == "$HASH2" ]]; do
    HASH2=$(printf '%s%s%s' "$RANDOM" "$RANDOM" "$RANDOM" | sha256sum | cut -c1-6)
  done

  FQDN_A1="vps-ns4-$HASH1.$DOMAIN"
  FQDN_A2="vps-nv4-$HASH2.$DOMAIN"
  NS4="ns4.$DOMAIN"
  NV4="nv4.$DOMAIN"

  info "Création des enregistrements Cloudflare..."

  cf_post() {
    curl -s -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      -H "Content-Type: application/json" \
      --data "$1" > /dev/null
  }

  cf_post "{\"type\":\"A\",\"name\":\"$FQDN_A1\",\"content\":\"$IP_PUBLIC\",\"ttl\":120,\"proxied\":false}"
  ok "A $FQDN_A1 → $IP_PUBLIC"
  cf_post "{\"type\":\"A\",\"name\":\"$FQDN_A2\",\"content\":\"$IP_PUBLIC\",\"ttl\":120,\"proxied\":false}"
  ok "A $FQDN_A2 → $IP_PUBLIC"
  cf_post "{\"type\":\"NS\",\"name\":\"$NS4\",\"content\":\"$FQDN_A1\",\"ttl\":120}"
  ok "NS $NS4 → $FQDN_A1"
  cf_post "{\"type\":\"NS\",\"name\":\"$NV4\",\"content\":\"$FQDN_A2\",\"ttl\":120}"
  ok "NS $NV4 → $FQDN_A2"

  warn "Propagation DNS : quelques minutes."

elif [[ "$MODE" == "2" ]]; then
  MODE="man"
  read -rp "  NS instance #1 (ssh) (ex: ns4.kingom.ggff.net) : " NS4
  read -rp "  NS instance #2 (v2ray) (ex: nv4.kingom.ggff.net) : " NV4
  ok "NS #1 : $NS4"
  ok "NS #2 : $NV4"
else
  err "Mode invalide."; exit 1
fi

printf 'MODE=%s\nNS4=%s\nNV4=%s\nDOMAIN=%s\nIP_PUBLIC=%s\n' "$MODE" "$NS4" "$NV4" "$DOMAIN" "$IP_PUBLIC" > "$SLOWDNS_DIR/install.env"

sep
echo -e "  ${C}Port 53${NC} → nftables DNAT → ${C}Port $ROUTER_PORT${NC} (routeur Python)"
echo -e "      ├── ${Y}$NS4${NC} → SlowDNS #1 (port $PORT1) → ${G}$BACKEND1_TARGET${NC}"
echo -e "      └── ${Y}$NV4${NC} → SlowDNS #2 (port $PORT2) → ${G}$BACKEND2_TARGET${NC}"
sep

info "Sauvegarde..."
mkdir -p "$BACKUP_DIR"
for f in /etc/nftables.conf /etc/iptables/rules.v4 /etc/sysctl.d/99-slowdns.conf; do
  [[ -f "$f" ]] && cp -a "$f" "$BACKUP_DIR/" 2>/dev/null
done
[[ -d "$SLOWDNS_DIR" ]] && cp -a "$SLOWDNS_DIR" "$BACKUP_DIR/slowdns/" 2>/dev/null
nft list ruleset > "$BACKUP_DIR/nftables-ruleset.txt" 2>/dev/null || true
iptables-save > "$BACKUP_DIR/iptables-save.txt" 2>/dev/null || true
ok "Sauvegarde → $BACKUP_DIR"

info "Installation des dépendances..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq 2>/dev/null
apt install -y -qq curl jq nftables python3 python3-pip 2>/dev/null
ok "Dépendances OK"

# Supprimer dnsdist s'il est installé
if dpkg -l | grep -q dnsdist; then
  info "Suppression de dnsdist..."
  systemctl stop dnsdist 2>/dev/null || true
  systemctl disable dnsdist 2>/dev/null || true
  apt remove -y dnsdist 2>/dev/null || true
  ok "dnsdist supprimé"
fi

if [[ ! -x "$SLOWDNS_BIN" ]]; then
  info "Téléchargement dnstt-server..."
  DNSTT_TMP=$(mktemp)
  curl -fsSL "https://dnstt-server-client.s3.amazonaws.com/dnstt-server-linux-amd64" -o "$DNSTT_TMP"
  FILESIZE=$(stat -c%s "$DNSTT_TMP")
  if [[ "$FILESIZE" -lt 1048576 ]]; then
    err "Binaire corrompu ($FILESIZE octets)"; rm -f "$DNSTT_TMP"; exit 1
  fi
  mv "$DNSTT_TMP" "$SLOWDNS_BIN"
  chmod +x "$SLOWDNS_BIN"
  ok "dnstt-server OK ($FILESIZE octets)"
else
  ok "dnstt-server déjà présent"
fi

info "Déploiement des clés..."
printf '%s\n' "$DNSTT_PRIV_KEY" > "$SERVER_KEY"
printf '%s\n' "$DNSTT_PUB_KEY"  > "$SERVER_PUB"
chmod 600 "$SERVER_KEY"; chmod 644 "$SERVER_PUB"
ok "Clés OK"

echo "$NS4" > "$CONFIG_FILE"
echo "$NV4" > "$SLOWDNS_DIR/nv4/ns.conf"

info "Création du routeur Python..."

cat > "$ROUTER_PY" << 'PYEOF'
#!/usr/bin/env python3
import socket
import sys
import logging
import select
import time
from datetime import datetime

# Configuration
LISTEN_IP = "0.0.0.0"
LISTEN_PORT = 5300
TUNNEL_HOST = "127.0.0.1"
TUNNEL_PORT1 = 5353  # Instance SSH
TUNNEL_PORT2 = 5354  # Instance V2Ray

# Domaines des tunnels
NS4 = "ns4.$DOMAIN"
NV4 = "nv4.$DOMAIN"

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler('/var/log/slowdns/router.log'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

def get_tunnel_port(domain):
    """Détermine le port de tunnel en fonction du domaine"""
    if NS4 in domain:
        return TUNNEL_PORT1
    elif NV4 in domain:
        return TUNNEL_PORT2
    return None

def main():
    # Création du socket
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind((LISTEN_IP, LISTEN_PORT))
    sock.setblocking(False)
    
    logger.info(f"Routeur DNS démarré sur {LISTEN_IP}:{LISTEN_PORT}")
    logger.info(f"Tunnel SSH: {NS4} -> {TUNNEL_HOST}:{TUNNEL_PORT1}")
    logger.info(f"Tunnel V2Ray: {NV4} -> {TUNNEL_HOST}:{TUNNEL_PORT2}")
    
    # Cache pour éviter de reparser les requêtes DNS
    pending_requests = {}
    
    while True:
        try:
            # Utilisation de select pour gérer l'asynchronisme
            ready, _, _ = select.select([sock], [], [], 1.0)
            
            if not ready:
                continue
                
            data, client_addr = sock.recvfrom(4096)
            
            # Extraire le domaine de la requête DNS (format simplifié)
            # Dans un vrai routeur, on parserait proprement le DNS
            try:
                # Recherche du nom de domaine dans la requête
                # Position approximative après l'en-tête DNS
                offset = 12  # En-tête DNS = 12 octets
                domain_parts = []
                while True:
                    length = data[offset]
                    if length == 0:
                        break
                    offset += 1
                    domain_parts.append(data[offset:offset+length].decode('ascii', errors='ignore'))
                    offset += length
                domain = '.'.join(domain_parts)
                logger.debug(f"Requête pour: {domain} de {client_addr}")
                
                # Déterminer le port de tunnel
                tunnel_port = get_tunnel_port(domain)
                if tunnel_port is None:
                    # Refuser les requêtes non autorisées
                    # Envoyer une réponse REFUSED (RCODE=5)
                    response = data[:2] + b'\x81\x85' + data[4:12] + data[12:]
                    # Ajuster l'offset pour répondre REFUSED
                    sock.sendto(response, client_addr)
                    logger.warning(f"Domaine non autorisé: {domain} -> REFUSED")
                    continue
                
                # Forward vers le bon tunnel
                sock.sendto(data, (TUNNEL_HOST, tunnel_port))
                
                # Attendre la réponse du tunnel
                # On utilise un timeout court car le tunnel répond rapidement
                # En production, on pourrait garder le socket en attente avec select
                response, _ = sock.recvfrom(4096)
                sock.sendto(response, client_addr)
                
                logger.debug(f"Requête relayée: {domain} -> port {tunnel_port}")
                
            except UnicodeDecodeError:
                # Si on ne peut pas parser, on refuse
                logger.warning(f"Requête malformée de {client_addr} -> REFUSED")
                response = data[:2] + b'\x81\x85' + data[4:12] + data[12:]
                sock.sendto(response, client_addr)
            except Exception as e:
                logger.error(f"Erreur de traitement: {e}")
                # En cas d'erreur, on répond REFUSED
                try:
                    response = data[:2] + b'\x81\x85' + data[4:12] + data[12:]
                    sock.sendto(response, client_addr)
                except:
                    pass
                    
        except KeyboardInterrupt:
            logger.info("Arrêt du routeur")
            break
        except Exception as e:
            logger.error(f"Erreur générale: {e}")
            time.sleep(1)

if __name__ == "__main__":
    # Remplacer les variables shell par leurs valeurs réelles
    import os
    globals()['NS4'] = os.getenv('NS4', 'ns4.kingom.ggff.net')
    globals()['NV4'] = os.getenv('NV4', 'nv4.kingom.ggff.net')
    main()
PYEOF

# Injection des variables réelles dans le routeur
sed -i "s/NS4 = \"ns4\.\$DOMAIN\"/NS4 = \"$NS4\"/" "$ROUTER_PY"
sed -i "s/NV4 = \"nv4\.\$DOMAIN\"/NV4 = \"$NV4\"/" "$ROUTER_PY"
chmod +x "$ROUTER_PY"

ok "Routeur Python créé: $ROUTER_PY"

info "Création des scripts de démarrage..."

cat > /usr/local/bin/slowdns-ns4-start.sh << STARTEOF
#!/bin/bash
NS=$(cat /etc/slowdns/ns.conf)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] slowdns-ns4 start NS=$NS" >> /var/log/slowdns/ns4.log
exec /usr/local/bin/dnstt-server -udp 0.0.0.0:${PORT1} -privkey-file /etc/slowdns/server.key "\$NS" ${BACKEND1_TARGET}
STARTEOF

cat > /usr/local/bin/slowdns-nv4-start.sh << STARTEOF
#!/bin/bash
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] slowdns-nv4 start" >> /var/log/slowdns/nv4.log
exec ${SLOWDNS_BIN} -udp 0.0.0.0:${PORT2} -privkey-file ${SLOWDNS_DIR}/server.key ${NV4} ${BACKEND2_TARGET}
STARTEOF

chmod +x /usr/local/bin/slowdns-ns4-start.sh /usr/local/bin/slowdns-nv4-start.sh
ok "Scripts OK"

info "Création des services systemd..."

# Service pour le routeur Python
cat > /etc/systemd/system/slowdns-router.service << ROUTERSERV
[Unit]
Description=Routeur DNS Python
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment="NS4=$NS4"
Environment="NV4=$NV4"
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 $ROUTER_PY
Restart=always
RestartSec=3
StartLimitBurst=0
LimitNOFILE=1048576
StandardOutput=append:/var/log/slowdns/router.log
StandardError=append:/var/log/slowdns/router.log

[Install]
WantedBy=multi-user.target
ROUTERSERV

for inst in ns4 nv4; do
  logfile="/var/log/slowdns/$inst.log"
  start_script="/usr/local/bin/slowdns-$inst-start.sh"
  cat > "/etc/systemd/system/slowdns-$inst.service" << SERVICEEOF
[Unit]
Description=SlowDNS DNSTT $inst
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
ExecStartPre=/bin/sleep 5
ExecStart=$start_script
Restart=always
RestartSec=5
StartLimitBurst=0
LimitNOFILE=1048576
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=10
StandardOutput=append:$logfile
StandardError=append:$logfile

[Install]
WantedBy=multi-user.target
SERVICEEOF
done
ok "Services systemd OK"

info "Configuration nftables..."

cat > /usr/local/bin/init-nftables.sh << NFTINIT
#!/bin/bash
# Cleanup et rechargement des règles
nft flush ruleset 2>/dev/null || true
nft -f /etc/nftables/slowdns.nft 2>/dev/null || true
NFTINIT
chmod +x /usr/local/bin/init-nftables.sh

mkdir -p /etc/nftables

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << NFTEOF
table inet slowdns {
	chain prerouting {
		type nat hook prerouting priority -100;
		udp dport 53 redirect to :${ROUTER_PORT}
		tcp dport 53 redirect to :${ROUTER_PORT}
	}
	chain input {
		type filter hook input priority 0; policy accept;
		udp dport 53 accept
		udp dport ${ROUTER_PORT} accept
		udp dport ${PORT1} accept
		udp dport ${PORT2} accept
		tcp dport 109 accept
		tcp dport 5401 accept
	}
}
NFTEOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/slowdns.nft
    chmod +x /usr/local/bin/init-nftables.sh
    /usr/local/bin/init-nftables.sh
    ok "Table nftables slowdns chargée et persistée"
else
    err "Erreur nftables"
    rm -f "$TMP_NFT"
    exit 1
fi

chattr -i /etc/resolv.conf 2>/dev/null || true
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
chattr +i /etc/resolv.conf && ok "resolv.conf verrouillé" || warn "chattr non disponible"

cat > /etc/sysctl.d/99-slowdns.conf << 'SYSCTLEOF'
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.core.rmem_default=1048576
net.core.wmem_default=1048576
net.core.netdev_max_backlog=5000
SYSCTLEOF
sysctl -p /etc/sysctl.d/99-slowdns.conf > /dev/null 2>&1 && ok "sysctl UDP buffers OK" || warn "sysctl non appliqué"

cat > /etc/logrotate.d/slowdns << 'LOGEOF'
/var/log/slowdns/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGEOF
ok "logrotate OK"

WATCHDOG_SCRIPT="/usr/local/bin/slowdns-watchdog.sh"
cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
LOG=/var/log/slowdns/watchdog.log
ts() { date '+%Y-%m-%d %H:%M:%S'; }
for svc in slowdns-router slowdns-ns4 slowdns-nv4; do
  systemctl is-active --quiet "\$svc" || { systemctl restart "\$svc"; echo "[\$(ts)] \$svc redémarré" >> "\$LOG"; }
done
for p in ${ROUTER_PORT} ${PORT1} ${PORT2}; do
  ss -ulpn | grep -q ":\$p " || { 
    if [ "\$p" == "${ROUTER_PORT}" ]; then
      systemctl restart slowdns-router
      echo "[\$(ts)] slowdns-router port \$p absent — redémarré" >> "\$LOG"
    elif [ "\$p" == "${PORT1}" ]; then
      systemctl restart slowdns-ns4
      echo "[\$(ts)] slowdns-ns4 port \$p absent — redémarré" >> "\$LOG"
    elif [ "\$p" == "${PORT2}" ]; then
      systemctl restart slowdns-nv4
      echo "[\$(ts)] slowdns-nv4 port \$p absent — redémarré" >> "\$LOG"
    fi
  }
done
WDEOF
chmod +x "$WATCHDOG_SCRIPT"
CRON_JOB="*/15 * * * * $WATCHDOG_SCRIPT"
( crontab -l 2>/dev/null | grep -v "slowdns"; echo "$CRON_JOB" ) | crontab -
ok "Cron watchdog toutes les 15 min"

if [[ "$MODE" == "auto" ]]; then
  UPDATE_IP_SCRIPT="/usr/local/bin/slowdns-update-ip.sh"
  cat > "$UPDATE_IP_SCRIPT" << IPEOF
#!/bin/bash
NEW_IP=\$(curl -s ipv4.icanhazip.com)
ENV_FILE="$SLOWDNS_DIR/install.env"
[[ -z "\$NEW_IP" ]] && exit 0
OLD_IP=\$(grep "^IP_PUBLIC=" "\$ENV_FILE" 2>/dev/null | cut -d= -f2)
[[ "\$NEW_IP" == "\$OLD_IP" ]] && exit 0
ZONE="$CF_ZONE_ID"
TOKEN="$CF_API_TOKEN"
for NAME in $FQDN_A1 $FQDN_A2; do
  REC_ID=\$(curl -s "https://api.cloudflare.com/client/v4/zones/\$ZONE/dns_records?type=A&name=\$NAME" \
    -H "Authorization: Bearer \$TOKEN" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4)
  [[ -z "\$REC_ID" ]] && continue
  curl -s -X PATCH "https://api.cloudflare.com/client/v4/zones/\$ZONE/dns_records/\$REC_ID" \
    -H "Authorization: Bearer \$TOKEN" -H "Content-Type: application/json" \
    --data "{\"content\":\"\$NEW_IP\"}" > /dev/null
done
sed -i "s/^IP_PUBLIC=.*/IP_PUBLIC=\$NEW_IP/" "\$ENV_FILE" 2>/dev/null || echo "IP_PUBLIC=\$NEW_IP" >> "\$ENV_FILE"
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] IP mise a jour : \$OLD_IP -> \$NEW_IP" >> /var/log/slowdns/watchdog.log
IPEOF
  chmod +x "$UPDATE_IP_SCRIPT"
  IP_CRON="*/30 * * * * $UPDATE_IP_SCRIPT"
  ( crontab -l 2>/dev/null | grep -v "slowdns-update-ip"; echo "$IP_CRON" ) | crontab -
  ok "Cron IP Cloudflare toutes les 30 min"
else
  warn "Mode manuel — cron IP Cloudflare ignoré"
fi

info "Démarrage des services..."
systemctl daemon-reload

for svc in slowdns-router slowdns-ns4 slowdns-nv4; do
  systemctl enable "$svc" 2>/dev/null || true
  systemctl restart "$svc" 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet "$svc"; then
    ok "$svc → actif"
  else
    err "$svc → échec (journalctl -u $svc -n 20 --no-pager)"
  fi
done

sep
echo -e "  ${B}VÉRIFICATION FINALE${NC}"
echo ""
for svc in slowdns-router slowdns-ns4 slowdns-nv4; do
  status=$(systemctl is-active "$svc" 2>/dev/null)
  [[ "$status" == "active" ]] && ok "$svc : $status" || err "$svc : $status"
done

echo ""
echo -e "  ${C}Ports :${NC}"
for p in $ROUTER_PORT $PORT1 $PORT2 5401 22; do
  ss -tulpn 2>/dev/null | grep -q ":$p " && ok "Port $p OK" || warn "Port $p absent"
done
nft list ruleset 2>/dev/null | grep -q "dport 53 redirect" && ok "Port 53 DNAT → $ROUTER_PORT OK" || warn "Règle DNAT 53 absente"

echo ""
echo -e "  ${C}Tests DNS :${NC}"
echo -e "  dig abc.$NS4 @127.0.0.1  → NXDOMAIN"
echo -e "  dig abc.$NV4 @127.0.0.1  → NXDOMAIN"
echo -e "  dig other.com @127.0.0.1 → REFUSED"
echo ""
echo -e "  ${C}Logs :${NC}"
echo -e "  tail -f /var/log/slowdns/router.log"
echo -e "  tail -f /var/log/slowdns/ns4.log"
echo -e "  tail -f /var/log/slowdns/nv4.log"
echo -e "  tail -f /var/log/slowdns/watchdog.log"

sep
echo -e "  ${Y}Rollback :${NC} $BACKUP_DIR"
echo -e "  systemctl stop slowdns-router slowdns-ns4 slowdns-nv4"
echo -e "  systemctl disable slowdns-router slowdns-ns4 slowdns-nv4"
echo -e "  rm -f /etc/systemd/system/slowdns-*.service"
echo -e "  rm -f $SLOWDNS_BIN /usr/local/bin/slowdns-*"
echo -e "  rm -f /etc/logrotate.d/slowdns"
echo -e "  chattr -i /etc/resolv.conf"
echo -e "  rm -f /etc/sysctl.d/99-slowdns.conf"
echo -e "  nft delete table inet slowdns"
echo -e "  rm -f /etc/nftables/slowdns.nft"
echo -e "  systemctl daemon-reload"

sep
echo -e "  ${G}${B}Installation terminée.${NC}"
echo -e "  Routeur Python : ${Y}Port $ROUTER_PORT${NC}"
echo -e "  Instance #1 : ${Y}$NS4${NC} → SSH:109"
echo -e "  Instance #2 : ${Y}$NV4${NC} → V2Ray:5401"
echo ""
