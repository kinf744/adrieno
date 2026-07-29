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
ROUTER_DIR="/root/Kighmu/slowdns-router"
ROUTER_BIN="$ROUTER_DIR/slowdns-router"
BACKUP_DIR="/root/backup-slowdns-$(date +%Y%m%d-%H%M%S)"
SERVER_KEY="$SLOWDNS_DIR/server.key"
SERVER_PUB="$SLOWDNS_DIR/server.pub"
CONFIG_FILE="$SLOWDNS_DIR/ns.conf"

DOMAIN="${DOMAIN:-kingom.ggff.net}"
IP_PUBLIC="${IP_PUBLIC:-$(curl -s --max-time 5 ipv4.icanhazip.com || echo "127.0.0.1")}"
BACKEND1_TARGET="${BACKEND1_TARGET:-127.0.0.1:109}"
BACKEND2_TARGET="${BACKEND2_TARGET:-127.0.0.1:5401}"
PORT1="${PORT1:-5353}"
PORT2="${PORT2:-5354}"

DNSTT_PRIV_KEY="${DNSTT_PRIV_KEY:-4ab3af05fc004cb69d50c89de2cd5d138be1c397a55788b8867088e801f7fcaa}"
DNSTT_PUB_KEY="${DNSTT_PUB_KEY:-2cb39d63928451bd67f5954ffa5ac16c8d903562a10c4b21756de4f1a82d581c}"

CF_API_TOKEN="${CF_API_TOKEN:-7mn4LKcZARvdbLlCVFTtaX7LGM2xsnyjHkiTAt37}"
CF_ZONE_ID="${CF_ZONE_ID:-7debbb8ea4946898a889c4b5745ab7eb}"

[[ "$EUID" -ne 0 ]] && { err "Exécutez en root"; exit 1; }

# ─── Nettoyage complet avant installation ──────────────────────────────

# Forcer déverrouillage resolv.conf
chattr -i /etc/resolv.conf 2>/dev/null || true

# Arrêt et désactivation de tous les services slowdns existants
for svc in slowdns-router slowdns-ns4 slowdns-nv4 slowdns; do
  systemctl stop "$svc" 2>/dev/null || true
  systemctl disable "$svc" 2>/dev/null || true
done

# Suppression des vieux fichiers service
rm -f /etc/systemd/system/slowdns-router.service
rm -f /etc/systemd/system/slowdns-ns4.service
rm -f /etc/systemd/system/slowdns-nv4.service
rm -f /etc/systemd/system/slowdns.service
rm -f /etc/systemd/system/dnsdist.service.d/restart.conf
rmdir /etc/systemd/system/dnsdist.service.d 2>/dev/null || true

# Kill tous les processus liés
for p in dnstt-server slowdns-router slowdns-ns4-start slowdns-nv4-start; do
  pkill -9 -f "$p" 2>/dev/null || true
done
sleep 1

# Vérifier que les ports sont libres
for port in 53 $PORT1 $PORT2; do
  if ss -uln | grep -q ":$port "; then
    warn "Port $port occupé, attente libération..."
    for i in 1 2 3 4 5; do
      sleep 1
      ss -uln | grep -q ":$port " || break
    done
    if ss -uln | grep -q ":$port "; then
      err "Port $port toujours occupé après 5s, abandon"
      exit 1
    fi
  fi
done

# Supprimer toute règle DNAT catch-all qui intercepterait le port 53
if iptables -t nat -C PREROUTING -i eth0 -p udp --dport 1:65535 -j DNAT --to-destination :36712 2>/dev/null; then
  iptables -t nat -D PREROUTING -i eth0 -p udp --dport 1:65535 -j DNAT --to-destination :36712
  ok "Règle DNAT catch-all 1-65535 → 36712 supprimée"
fi
# Exclure le port 53 du DNAT de la table udp_custom (insérer en tête)
nft insert rule inet udp_custom prerouting udp dport 53 return 2>/dev/null || true
ok "Port 53 exclu du DNAT udp_custom"

# Nettoyage nftables ancienne table
nft delete table inet slowdns 2>/dev/null || true
rm -f /etc/nftables/slowdns.nft
systemctl disable --now nftables-tunnel@slowdns.service 2>/dev/null || true

# Suppression des anciens fichiers
rm -f /usr/local/bin/slowdns-ns4-start.sh
rm -f /usr/local/bin/slowdns-nv4-start.sh
rm -f /usr/local/bin/slowdns-update-ip.sh
rm -f /usr/local/bin/slowdns-watchdog.sh
rm -f /etc/logrotate.d/slowdns
rm -f /etc/sysctl.d/99-slowdns.conf

# Suppression des anciens répertoires (sauf backup)
rm -rf /var/log/slowdns
rm -rf /etc/slowdns

# Nettoyage Go build cache (évite corruption entre installations)
rm -rf "$ROUTER_DIR"

# Nettoyage crons slowdns
crontab -l 2>/dev/null | grep -v "slowdns" | crontab - 2>/dev/null || true

systemctl daemon-reload

# ─── Début installation propre ─────────────────────────────────────────

clear
echo -e "${C}${B}"
cat << 'EOF'
  ╔══════════════════════════════════════════════════╗
  ║     SlowDNS v3 — Dual-Instance (Go Router)       ║
  ╚══════════════════════════════════════════════════╝
EOF
echo -e "${NC}"
sep

mkdir -p "$SLOWDNS_DIR/ns4" "$SLOWDNS_DIR/nv4" /var/log/slowdns "$ROUTER_DIR"

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
      --data "$1" > /dev/null 2>&1
  }

  cf_post "{\"type\":\"A\",\"name\":\"$FQDN_A1\",\"content\":\"$IP_PUBLIC\",\"ttl\":120,\"proxied\":false}" || true
  ok "A $FQDN_A1 → $IP_PUBLIC"
  cf_post "{\"type\":\"A\",\"name\":\"$FQDN_A2\",\"content\":\"$IP_PUBLIC\",\"ttl\":120,\"proxied\":false}" || true
  ok "A $FQDN_A2 → $IP_PUBLIC"
  cf_post "{\"type\":\"NS\",\"name\":\"$NS4\",\"content\":\"$FQDN_A1\",\"ttl\":120}" || true
  ok "NS $NS4 → $FQDN_A1"
  cf_post "{\"type\":\"NS\",\"name\":\"$NV4\",\"content\":\"$FQDN_A2\",\"ttl\":120}" || true
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
echo -e "  ${C}Port 53${NC} → slowdns-router (Go)"
echo -e "      ├── ${Y}$NS4${NC} → SlowDNS #1 (port $PORT1) → ${G}$BACKEND1_TARGET${NC}"
echo -e "      └── ${Y}$NV4${NC} → SlowDNS #2 (port $PORT2) → ${G}$BACKEND2_TARGET${NC}"
sep

info "Installation des dépendances..."
export DEBIAN_FRONTEND=noninteractive
apt update -qq 2>/dev/null || true
apt install -y -qq --no-install-recommends curl jq nftables golang-go 2>/dev/null || \
apt install -y -qq --no-install-recommends curl jq nftables golang 2>/dev/null || true
ok "Dépendances OK"

if [[ ! -x "$SLOWDNS_BIN" ]]; then
  info "Téléchargement dnstt-server..."
  DNSTT_TMP=$(mktemp)
  curl -fsSL --max-time 30 "https://dnstt-server-client.s3.amazonaws.com/dnstt-server-linux-amd64" -o "$DNSTT_TMP" || {
    err "Échec téléchargement dnstt-server"; rm -f "$DNSTT_TMP"; exit 1
  }
  FILESIZE=$(stat -c%s "$DNSTT_TMP" 2>/dev/null || echo "0")
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

info "Création des scripts de démarrage dnstt..."

cat > /usr/local/bin/slowdns-ns4-start.sh << 'STARTEOF'
#!/bin/bash
exec 2>&1
NS=$(cat /etc/slowdns/ns.conf)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] slowdns-ns4 start NS=$NS"
exec /usr/local/bin/dnstt-server -udp 0.0.0.0:5353 -privkey-file /etc/slowdns/server.key "$NS" 127.0.0.1:109
STARTEOF

cat > /usr/local/bin/slowdns-nv4-start.sh << STARTEOF
#!/bin/bash
exec 2>&1
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] slowdns-nv4 start"
exec ${SLOWDNS_BIN} -udp 0.0.0.0:${PORT2} -privkey-file ${SLOWDNS_DIR}/server.key ${NV4} ${BACKEND2_TARGET}
STARTEOF

chmod +x /usr/local/bin/slowdns-ns4-start.sh /usr/local/bin/slowdns-nv4-start.sh
ok "Scripts dnstt OK"

info "Création des services systemd dnstt (résistants aux crashs)..."

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
Type=simple
ExecStartPre=/bin/sleep 3
ExecStart=$start_script
Restart=always
RestartSec=3
StartLimitBurst=0
StartLimitIntervalSec=0
LimitNOFILE=1048576
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=15
StandardOutput=append:$logfile
StandardError=append:$logfile

[Install]
WantedBy=multi-user.target
SERVICEEOF
done
ok "Services dnstt OK"

info "Compilation du routeur Go..."
mkdir -p "$ROUTER_DIR"
cat > "$ROUTER_DIR/main.go" << 'GOEOF'
package main

import (
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
)

type route struct {
	domain string
	addr   *net.UDPAddr
}

type stats struct {
	mu      sync.Mutex
	total   int64
	routed  map[string]int64
	refused int64
	errors  int64
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		n, err := fmt.Sscanf(v, "%d", &fallback)
		if n == 1 && err == nil {
			return fallback
		}
	}
	return fallback
}

func main() {
	listen := getEnv("LISTEN", "0.0.0.0:53")
	timeout := time.Duration(getEnvInt("TIMEOUT", 5)) * time.Second
	verbose := os.Getenv("VERBOSE") == "1"
	routesDef := getEnv("ROUTES", "")

	if routesDef == "" {
		log.Fatal("ROUTES env var required")
	}

	var routes []route
	for _, part := range strings.Split(routesDef, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		eq := strings.IndexByte(part, '=')
		if eq < 1 {
			log.Fatalf("invalid route %q (expected domain=addr)", part)
		}
		domain := strings.ToLower(strings.TrimSuffix(part[:eq], "."))
		addrStr := part[eq+1:]
		addr, err := net.ResolveUDPAddr("udp4", addrStr)
		if err != nil {
			log.Fatalf("resolve %s: %v", addrStr, err)
		}
		routes = append(routes, route{domain: domain, addr: addr})
	}
	if len(routes) == 0 {
		log.Fatal("no routes configured in ROUTES")
	}

	var st stats
	st.routed = make(map[string]int64)

	laddr, err := net.ResolveUDPAddr("udp4", listen)
	if err != nil {
		log.Fatalf("resolve listen %s: %v", listen, err)
	}

	conn, err := net.ListenUDP("udp4", laddr)
	if err != nil {
		log.Fatalf("listen %s: %v", listen, err)
	}
	defer conn.Close()

	conn.SetReadBuffer(16 * 1024 * 1024)
	conn.SetWriteBuffer(16 * 1024 * 1024)

	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM, syscall.SIGUSR1)

	go func() {
		for sig := range sigCh {
			switch sig {
			case syscall.SIGUSR1:
				printStats(&st)
			default:
				log.Println("shutting down...")
				conn.Close()
			}
		}
	}()

	log.Printf("slowdns-router listening on %s", listen)
	for _, r := range routes {
		log.Printf("  %s -> %s", r.domain, r.addr)
	}
	log.Println("send SIGUSR1 for stats")

	buf := make([]byte, 4096)
	for {
		n, clientAddr, err := conn.ReadFromUDP(buf)
		if err != nil {
			if !strings.Contains(err.Error(), "closed") {
				log.Printf("read error: %v", err)
			}
			break
		}

		st.mu.Lock()
		st.total++
		st.mu.Unlock()

		packet := make([]byte, n)
		copy(packet, buf[:n])
		go handle(conn, clientAddr, packet, routes, timeout, verbose, &st)
	}

	printStats(&st)
}

func handle(conn *net.UDPConn, clientAddr *net.UDPAddr, packet []byte, routes []route, timeout time.Duration, verbose bool, st *stats) {
	qname, err := extractQName(packet)
	if err != nil {
		if verbose {
			log.Printf("parse error from %s: %v", clientAddr, err)
		}
		return
	}
	qname = strings.ToLower(qname)
	if !strings.HasSuffix(qname, ".") {
		qname += "."
	}

	for _, r := range routes {
		if strings.HasSuffix(qname, r.domain+".") {
			if verbose {
				log.Printf("[%s] %s -> %s", r.domain, clientAddr, r.addr)
			}

			resp, err := forward(packet, r.addr, timeout)
			if err != nil {
				st.mu.Lock()
				st.errors++
				st.mu.Unlock()
				if verbose {
					log.Printf("error from %s: %v", r.addr, err)
				}
				sendRefused(conn, clientAddr, packet)
				return
			}

			st.mu.Lock()
			st.routed[r.domain]++
			st.mu.Unlock()

			conn.WriteToUDP(resp, clientAddr)
			return
		}
	}

	if verbose {
		log.Printf("REFUSED %s from %s", qname, clientAddr)
	}
	st.mu.Lock()
	st.refused++
	st.mu.Unlock()
	sendRefused(conn, clientAddr, packet)
}

func extractQName(packet []byte) (string, error) {
	if len(packet) < 12 {
		return "", fmt.Errorf("packet too short: %d", len(packet))
	}

	var labels []string
	pos := 12

	for {
		if pos >= len(packet) {
			return "", fmt.Errorf("truncated name at offset %d", pos)
		}
		length := int(packet[pos])
		if length == 0 {
			pos++
			break
		}
		if length&0xC0 != 0 {
			return "", fmt.Errorf("compressed name (unsupported)")
		}
		pos++
		if pos+length > len(packet) {
			return "", fmt.Errorf("label length %d exceeds packet at offset %d", length, pos)
		}
		labels = append(labels, string(packet[pos:pos+length]))
		pos += length
	}

	return strings.Join(labels, "."), nil
}

func forward(packet []byte, backend *net.UDPAddr, timeout time.Duration) ([]byte, error) {
	backendConn, err := net.DialUDP("udp4", nil, backend)
	if err != nil {
		return nil, fmt.Errorf("dial: %w", err)
	}
	defer backendConn.Close()

	backendConn.SetDeadline(time.Now().Add(timeout))

	if _, err := backendConn.Write(packet); err != nil {
		return nil, fmt.Errorf("write: %w", err)
	}

	resp := make([]byte, 4096)
	n, err := backendConn.Read(resp)
	if err != nil {
		return nil, fmt.Errorf("read: %w", err)
	}

	resp2 := make([]byte, n)
	copy(resp2, resp[:n])
	return resp2, nil
}

func sendRefused(conn *net.UDPConn, clientAddr *net.UDPAddr, req []byte) {
	if len(req) < 12 {
		return
	}
	resp := make([]byte, len(req))
	copy(resp, req)

	resp[2] = (req[2] & 0x01) | 0x80
	resp[3] = 0x85
	resp[6] = 0
	resp[7] = 0
	resp[8] = 0
	resp[9] = 0
	resp[10] = 0
	resp[11] = 0

	conn.WriteToUDP(resp, clientAddr)
}

func printStats(st *stats) {
	st.mu.Lock()
	defer st.mu.Unlock()
	fmt.Fprintf(os.Stderr, "\n--- slowdns-router stats ---\n")
	fmt.Fprintf(os.Stderr, "  total:   %d\n", st.total)
	for domain, count := range st.routed {
		fmt.Fprintf(os.Stderr, "  %s: %d\n", domain, count)
	}
	fmt.Fprintf(os.Stderr, "  refused: %d\n", st.refused)
	fmt.Fprintf(os.Stderr, "  errors:  %d\n", st.errors)
	fmt.Fprintf(os.Stderr, "----------------------------\n")
}
GOEOF

cd "$ROUTER_DIR"
go mod init slowdns-router 2>/dev/null || true
go clean -cache 2>/dev/null || true
go build -ldflags="-s -w" -o slowdns-router . && \
  ok "Routeur Go compilé ($(stat -c%s slowdns-router 2>/dev/null || echo "?") octets)" || \
  { err "Échec compilation Go"; exit 1; }

info "Création du service systemd routeur (démarré après dnstt)..."
cat > /etc/systemd/system/slowdns-router.service << SERVICEEOF
[Unit]
Description=SlowDNS Go Router (DNSTT traffic splitter)
After=network-online.target slowdns-ns4.service slowdns-nv4.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
Environment=LISTEN=0.0.0.0:53
Environment=ROUTES=${NS4}=127.0.0.1:${PORT1},${NV4}=127.0.0.1:${PORT2}
Environment=TIMEOUT=5
ExecStart=${ROUTER_BIN}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=3
StartLimitBurst=0
StartLimitIntervalSec=0
LimitNOFILE=1048576
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
SERVICEEOF
ok "Service routeur OK"

info "Configuration nftables..."

/usr/local/bin/init-nftables.sh 2>/dev/null || true

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << NFTEOF
table inet slowdns {
	chain input {
		type filter hook input priority 0; policy accept;
		udp dport 53 accept
		udp dport ${PORT1} accept
		udp dport ${PORT2} accept
		tcp dport 109 accept
		tcp dport 5401 accept
	}
}
NFTEOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/slowdns.nft
    systemctl daemon-reload
    systemctl enable --now nftables-tunnel@slowdns.service 2>/dev/null || true
    systemctl restart nftables-tunnel@slowdns.service 2>/dev/null || true
    ok "Table nftables slowdns chargée et persistée"
else
    err "Erreur nftables"
    rm -f "$TMP_NFT"
    exit 1
fi

# ─── Configuration système (sans risk de blocage) ─────────────────────

# resolv.conf : toujours dévérrouiller d'abord
chattr -i /etc/resolv.conf 2>/dev/null || true
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null && ok "resolv.conf verrouillé" || warn "chattr non disponible"

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

# ─── Watchdog renforcé ──────────────────────────────────────────────────

WATCHDOG_SCRIPT="/usr/local/bin/slowdns-watchdog.sh"
cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
LOG=/var/log/slowdns/watchdog.log
ts() { date '+%Y-%m-%d %H:%M:%S'; }

for svc in slowdns-ns4 slowdns-nv4 slowdns-router; do
  if ! systemctl is-active --quiet "\$svc"; then
    systemctl restart "\$svc"
    echo "[\$(ts)] \$svc redémarré" >> "\$LOG"
  fi
done

for port in ${PORT1} ${PORT2} 53; do
  if ! ss -ulpn | grep -q ":\$port "; then
    case \$port in
      ${PORT1}) systemctl restart slowdns-ns4 ;;
      ${PORT2}) systemctl restart slowdns-nv4 ;;
      53)       systemctl restart slowdns-router ;;
    esac
    echo "[\$(ts)] port \$port absent — service redémarré" >> "\$LOG"
  fi
done
WDEOF
chmod +x "$WATCHDOG_SCRIPT"

# Ajout watchdog au cron sans doublon
CRON_JOB="*/5 * * * * $WATCHDOG_SCRIPT"
( crontab -l 2>/dev/null | grep -v "slowdns-watchdog\|slowdns-update-ip" | grep -v "slowdns" || true; echo "$CRON_JOB" ) | crontab -
ok "Cron watchdog toutes les 5 min (au lieu de 15)"

if [[ "$MODE" == "auto" ]]; then
  UPDATE_IP_SCRIPT="/usr/local/bin/slowdns-update-ip.sh"
  cat > "$UPDATE_IP_SCRIPT" << IPEOF
#!/bin/bash
NEW_IP=\$(curl -s --max-time 10 ipv4.icanhazip.com)
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
  ( crontab -l 2>/dev/null | grep -v "slowdns-update-ip" | grep -v "slowdns" || true; echo "$IP_CRON" ) | crontab -
  ok "Cron IP Cloudflare toutes les 30 min"
else
  warn "Mode manuel — cron IP Cloudflare ignoré"
fi

# ─── Démarrage des services (ordre : dnstt → routeur) ─────────────────

info "Démarrage des services..."
systemctl daemon-reload

# S'assurer que dnsdist ne bloque pas le port 53
systemctl stop dnsdist 2>/dev/null || true
systemctl disable dnsdist 2>/dev/null || true

# Démarrer dnstt d'abord
for svc in slowdns-ns4 slowdns-nv4; do
  systemctl enable "$svc" 2>/dev/null || true
  systemctl restart "$svc" 2>/dev/null || true
  sleep 2
  if systemctl is-active --quiet "$svc"; then
    ok "$svc → actif"
  else
    err "$svc → échec (journalctl -u $svc -n 10 --no-pager)"
  fi
done

# Puis le routeur
systemctl enable slowdns-router 2>/dev/null || true
systemctl restart slowdns-router 2>/dev/null || true
sleep 1
if systemctl is-active --quiet slowdns-router; then
  ok "slowdns-router → actif"
else
  err "slowdns-router → échec (journalctl -u slowdns-router -n 10 --no-pager)"
fi

# ─── Vérification finale ────────────────────────────────────────────────

sep
echo -e "  ${B}VÉRIFICATION FINALE${NC}"
echo ""
for svc in slowdns-ns4 slowdns-nv4 slowdns-router; do
  status=$(systemctl is-active "$svc" 2>/dev/null)
  [[ "$status" == "active" ]] && ok "$svc : $status" || err "$svc : $status"
done

echo ""
echo -e "  ${C}Ports :${NC}"
for p in 53 $PORT1 $PORT2 5401 22; do
  ss -tulpn 2>/dev/null | grep -q ":$p " && ok "Port $p OK" || warn "Port $p absent"
done

echo ""
echo -e "  ${C}Tests DNS :${NC}"
echo -e "  dig abc.$NS4 @127.0.0.1  → NXDOMAIN"
echo -e "  dig abc.$NV4 @127.0.0.1  → NXDOMAIN"
echo -e "  dig other.com @127.0.0.1 → REFUSED"
echo ""
echo -e "  ${C}Logs :${NC}"
echo -e "  journalctl -u slowdns-router -f"
echo -e "  tail -f /var/log/slowdns/ns4.log"
echo -e "  tail -f /var/log/slowdns/nv4.log"
echo -e "  tail -f /var/log/slowdns/watchdog.log"

sep
echo -e "  ${Y}Rollback :${NC} $BACKUP_DIR"
echo -e "  systemctl stop slowdns-ns4 slowdns-nv4 slowdns-router"
echo -e "  systemctl disable slowdns-ns4 slowdns-nv4 slowdns-router"
echo -e "  rm -f /etc/systemd/system/slowdns-*.service"
echo -e "  rm -f $SLOWDNS_BIN ${ROUTER_BIN}"
echo -e "  rm -rf $ROUTER_DIR"
echo -e "  rm -f /etc/logrotate.d/slowdns"
echo -e "  chattr -i /etc/resolv.conf"
echo -e "  rm -f /etc/sysctl.d/99-slowdns.conf"
echo -e "  nft delete table inet slowdns"
echo -e "  rm -f /etc/nftables/slowdns.nft"
echo -e "  systemctl disable --now nftables-tunnel@slowdns.service"
echo -e "  systemctl daemon-reload"

sep
echo -e "  ${G}${B}Installation terminée.${NC}"
echo -e "  Routeur Go : port 53 direct (plus de dnsdist)"
echo -e "  Instance #1 : ${Y}$NS4${NC} → SSH:22"
echo -e "  Instance #2 : ${Y}$NV4${NC} → V2Ray:5401"
echo ""
