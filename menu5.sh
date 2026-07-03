#!/bin/bash
# menu5.sh - Panneau de contrôle installation/désinstallation amélioré

# Définition des couleurs
RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
BOLD="\e[1m"
RESET="\e[0m"

afficher_modes_ports() {
    local any_active=0

    if systemctl is-active --quiet ssh || pgrep -x sshd >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet dropbear.service || pgrep -x dropbear >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet slowdns-ns4.service || pgrep -f "sldns-server" >/dev/null 2>&1 || screen -list | grep -q slowdns_session; then any_active=1; fi
    if systemctl is-active --quiet udp-custom.service || pgrep -f udp-custom-linux-amd64 >/dev/null 2>&1 || screen -list | grep -q udp-custom; then any_active=1; fi
    if systemctl is-active --quiet socks_python.service || pgrep -f KIGHMUPROXY.py >/dev/null 2>&1 || screen -list | grep -q socks_python; then any_active=1; fi
    if systemctl is-active --quiet socks_python_ws.service || pgrep -f ws2_proxy.py >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet ssl_tls.service || pgrep -f stunnel >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet badvpn.service || pgrep -f "badvpn-udpgw" >/dev/null 2>&1 || screen -list | grep -q badvpn_session; then any_active=1; fi
    if systemctl is-active --quiet histeria2.service || pgrep -f hysteria >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet sshws.service || pgrep -f sshws >/dev/null 2>&1; then any_active=1; fi
    if systemctl is-active --quiet udp_request.service || pgrep -f udp_request >/dev/null 2>&1; then any_active=1; fi

    if [[ $any_active -eq 0 ]]; then
        return
    fi

    echo -e "${CYAN}Modes actifs et ports utilisés:${RESET}"

    if systemctl is-active --quiet ssh || pgrep -x sshd >/dev/null 2>&1; then
        echo -e "  - OpenSSH: ${GREEN}port 22${RESET}"
    fi
    if systemctl is-active --quiet dropbear.service || pgrep -x dropbear >/dev/null 2>&1; then
        DROPBEAR_PORT=$(grep -oP '(?<=-p )\d+' /etc/default/dropbear 2>/dev/null || echo "109")
        echo -e "  - Dropbear: ${GREEN}port $DROPBEAR_PORT${RESET}"
    fi
    if systemctl is-active --quiet slowdns-ns4.service || pgrep -f "sldns-server" >/dev/null 2>&1 || screen -list | grep -q slowdns_session; then
        echo -e "  - SlowDNS: ${GREEN}ports UDP 5353${RESET}"
    fi
    if systemctl is-active --quiet udp-custom.service || pgrep -f ud-custom-linux-amd64 >/dev/null 2>&1 || screen -list | grep -q udp-custom; then
        echo -e "  - UDP Custom: ${GREEN}port UDP 1-65535${RESET}"
    fi
    if systemctl is-active --quiet socks_python.service || pgrep -f KIGHMUPROXY.py >/dev/null 2>&1 || screen -list | grep -q socks_python; then
        echo -e "  - SOCKS Python: ${GREEN}ports TCP 8080${RESET}"
    fi
    if systemctl is-active --quiet socks_python_ws.service || pgrep -f ws2_proxy.py >/dev/null 2>&1; then
        if [ -f /etc/systemd/system/socks_python_ws.service ]; then
            PROXY_WS_PORT=$(grep "ExecStart=" /etc/systemd/system/socks_python_ws.service | awk '{print $NF}')
        else
            PROXY_WS_PORT=$(sudo lsof -Pan -p $(pgrep -f ws2_proxy.py | head -n1) -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $9}' | cut -d: -f2)
        fi
        PROXY_WS_PORT=${PROXY_WS_PORT:-9090}
        echo -e "  - proxy ws: ${GREEN}port TCP $PROXY_WS_PORT${RESET}"
    fi
    if systemctl is-active --quiet ssl_tls.service || pgrep -f stunnel >/dev/null 2>&1; then
        echo -e "  - Stunnel SSL/TLS: ${GREEN}port TCP 444${RESET}"
    fi
    if systemctl is-active --quiet badvpn.service || pgrep -f stunnel >/dev/null 2>&1; then
        echo -e "  - badvpn: ${GREEN}port UDP 7300${RESET}"
    fi
    if systemctl is-active --quiet histeria2.service || pgrep -f hysteria >/dev/null 2>&1; then
        echo -e "  - Hysteria 2 UDP : ${GREEN}port UDP 20000${RESET}"
    fi
    if systemctl is-active --quiet sshws.service || pgrep -f sshws >/dev/null 2>&1 || screen -list | grep -q ws_wssr; then
        echo -e "  - WS/WSS Tunnel: ${GREEN}WS port 80 | WSS port 443${RESET}"
    fi
    if systemctl is-active --quiet udp_request.service || pgrep -f udp_reuest >/dev/null 2>&1 || screen -list | grep -q udp_request; then
        echo -e "  - UDP_request: ${GREEN}4466${RESET}"
    fi
}

# --- Fonctions d'installation et désinstallation existantes ---
install_slowdns() {
  echo ">>> Nettoyage avant installation SlowDNS v3..."

  # Arrêt et suppression des anciens services (v1 et v3)
  for svc in slowdns slowdns-ns4 slowdns-nv4; do
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
  done
  rm -f /etc/systemd/system/slowdns.service
  rm -f /etc/systemd/system/slowdns-ns4.service
  rm -f /etc/systemd/system/slowdns-nv4.service
  rm -f /etc/systemd/system/dnsdist.service.d/restart.conf
  rmdir /etc/systemd/system/dnsdist.service.d 2>/dev/null || true
  systemctl stop dnsdist 2>/dev/null || true
  systemctl disable dnsdist 2>/dev/null || true
  systemctl daemon-reload

  # Kill processus résiduels
  pkill -15 -f dnstt-server 2>/dev/null || true
  pkill -15 -f slowdns 2>/dev/null || true
  sleep 2
  pkill -9 -f dnstt-server 2>/dev/null || true

  # Suppression fichiers v1 et v3
  rm -f /usr/local/bin/dnstt-server
  rm -f /usr/local/bin/slowdns
  rm -f /usr/local/bin/slowdns-ns4-start.sh
  rm -f /usr/local/bin/slowdns-nv4-start.sh
  rm -f /usr/local/bin/slowdns-update-ip.sh
  rm -rf /etc/slowdns
  rm -rf "$HOME/.slowdns"
  rm -rf /var/log/slowdns
  rm -f /etc/logrotate.d/slowdns
  rm -f /etc/dnsdist/dnsdist.conf

  # Suppression crons slowdns
  ( crontab -l 2>/dev/null | grep -v "slowdns" ) | crontab -

  # Nettoyage firewall (nftables)
  nft delete table ip slowdns 2>/dev/null || true
  nft delete table ip filter 2>/dev/null || true
  nft delete table ip6 filter 2>/dev/null || true
  apt-mark unhold dnsdist 2>/dev/null || true

  echo ">>> Installation SlowDNS v3..."
  bash "$HOME/Kighmu/slowdns.sh" || echo "SlowDNS v3 : script introuvable."
}

uninstall_slowdns() {
  print_title
  echo "[5] DÉSINSTALLATION SLOWDNS (SAUF ZIVPN/Hysteria)"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  systemctl stop slowdns-ns4 slowdns-nv4 2>/dev/null || true
  systemctl disable slowdns-ns4 slowdns-nv4 2>/dev/null || true
  rm -f /etc/systemd/system/slowdns-ns4.service
  rm -f /etc/systemd/system/slowdns-nv4.service

  rm -f /etc/systemd/system/dnsdist.service.d/restart.conf
  rmdir /etc/systemd/system/dnsdist.service.d 2>/dev/null || true
  systemctl stop dnsdist 2>/dev/null || true
  systemctl disable dnsdist 2>/dev/null || true

  systemctl daemon-reload

  pkill -15 -f dnstt-server 2>/dev/null || true
  pkill -15 -f slowdns-ns4-start.sh 2>/dev/null || true
  pkill -15 -f slowdns-nv4-start.sh 2>/dev/null || true
  sleep 2
  pkill -9 -f dnstt-server 2>/dev/null || true

  rm -f /usr/local/bin/dnstt-server
  rm -f /usr/local/bin/slowdns-ns4-start.sh
  rm -f /usr/local/bin/slowdns-nv4-start.sh
  rm -f /usr/local/bin/slowdns-update-ip.sh
  rm -f /usr/local/bin/slowdns-watchdog.sh
  rm -rf /etc/slowdns
  rm -rf /var/log/slowdns
  rm -f /etc/logrotate.d/slowdns
  rm -f /etc/dnsdist/dnsdist.conf

  chattr -i /etc/resolv.conf 2>/dev/null || true

  rm -f /etc/sysctl.d/99-slowdns.conf
  sysctl --system > /dev/null 2>&1 || true

  ( crontab -l 2>/dev/null | grep -v "slowdns" ) | crontab -

  nft delete table inet slowdns 2>/dev/null || true
  rm -f /etc/nftables/slowdns.nft
  systemctl disable --now nftables-tunnel@slowdns.service 2>/dev/null || true
  systemctl daemon-reload

  apt-mark unhold dnsdist 2>/dev/null || true

  echo "✅ SlowDNS v3 supprimé SANS toucher ZIVPN/Hysteria"
  echo "   Vérifiez : nft list tables"
  echo "   Vérifiez : crontab -l"
}

install_openssh() {
    echo ">>> Installation d'OpenSSH..."
    apt-get install -y openssh-server
    systemctl enable ssh
    systemctl start ssh
    echo -e "${GREEN}[OK] OpenSSH installé.${RESET}"
}

uninstall_openssh() {
    echo ">>> Désinstallation d'OpenSSH..."
    apt-get remove -y openssh-server
    systemctl disable ssh
    echo -e "${GREEN}[OK] OpenSSH supprimé.${RESET}"
}

install_dropbear() {
    echo ">>> Installation dropbear via script..."
    bash "$HOME/Kighmu/dropbear.sh" || echo "Script introuvable."
}

uninstall_dropbear() {
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    NC='\033[0m'

    echo -e "${GREEN}>>> Désinstallation complète de Dropbear...${NC}"

    # Arrêt des services Dropbear actifs
    for svc in dropbear dropbear-custom; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            systemctl stop "$svc" 2>/dev/null || true
            echo "Service $svc arrêté"
        fi
        if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            systemctl disable "$svc" 2>/dev/null || true
            echo "Service $svc désactivé"
        fi
    done

    # Suppression des services systemd
    for file in /etc/systemd/system/dropbear.service /etc/systemd/system/dropbear-custom.service; do
        if [[ -f "$file" ]]; then
            rm -f "$file"
            echo "Service systemd $file supprimé"
        fi
    done

    systemctl daemon-reload

    # Suppression du paquet et dépendances
    apt-get remove -y dropbear
    apt-get autoremove -y

    # Suppression des fichiers de config et logs
    [[ -f /etc/default/dropbear ]] && rm -f /etc/default/dropbear
    [[ -d /etc/dropbear ]] && rm -rf /etc/dropbear
    [[ -f /var/log/dropbear-port109.log ]] && rm -f /var/log/dropbear-port109.log
    [[ -f /var/log/dropbear_custom.log ]] && rm -f /var/log/dropbear_custom.log

    echo -e "${GREEN}[OK] Dropbear désinstallé complètement.${NC}"
}

install_udp_custom() {
    echo ">>> Installation dropbear via script..."
    bash "$HOME/Kighmu/udp_custom.sh" || echo "Script introuvable."
}


uninstall_udp_custom() {
  print_title
  echo "[5] DÉSINSTALLATION UDP-CUSTOM (SAUF ZIVPN/Hysteria/SlowDNS)"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  # 1) Service seulement
  systemctl stop udp-custom.service 2>/dev/null || true
  systemctl disable udp-custom.service 2>/dev/null || true
  rm -f /etc/systemd/system/udp-custom.service
  systemctl daemon-reload
  systemctl reset-failed udp-custom.service 2>/dev/null || true

  # 2) Fichiers UDP-CUSTOM UNIQUEMENT
  rm -f /usr/local/bin/udp-custom
  rm -rf /etc/udp-custom
  rm -f /var/log/udp-custom 2>/dev/null || true

  # 3) NFTABLES UDP-CUSTOM UNIQUEMENT (EXACT match installation)
  nft delete table inet udp-custom 2>/dev/null || true
  rm -f /etc/nftables/udp-custom.nft
  systemctl disable --now nftables-tunnel@udp-custom.service 2>/dev/null || true
  systemctl daemon-reload

  echo "✅ UDP-Custom supprimé SANS toucher autres tunnels"
  echo "   Vérifiez: nft list chain inet kighmu input | grep 36712"
  pause
}

install_socks_python() {
    echo ">>> Installation SOCKS Python via script..."
    bash "$HOME/Kighmu/socks_python.sh" || echo "Script introuvable."
}

uninstall_socks_python() {
    echo ">>> Désinstallation complète SOCKS Python..."
    
    # Arrêt des processus proxy
    pids=$(pgrep -f KIGHMUPROXY.py)
    if [ -n "$pids" ]; then
        echo "Arrêt des processus proxy (PID: $pids)..."
        kill -15 $pids
        sleep 2
        pids=$(pgrep -f KIGHMUPROXY.py)
        [ -n "$pids" ] && kill -9 $pids
    fi

    # Arrêt et suppression du service systemd
    if systemctl list-units --full -all | grep -Fq 'socks_python.service'; then
        systemctl stop socks_python.service
        systemctl disable socks_python.service
        rm -f /etc/systemd/system/socks_python.service
        systemctl daemon-reload
    fi

    # Suppression du script
    rm -f /usr/local/bin/KIGHMUPROXY.py

    # Suppression de la table nftables socks-python
    nft delete table inet socks-python 2>/dev/null || true
    rm -f /etc/nftables/socks-python.nft
    systemctl disable --now nftables-tunnel@socks-python.service 2>/dev/null || true
    systemctl daemon-reload
    echo -e "${GREEN}[OK] SOCKS Python désinstallé.${RESET}"
}

install_proxy_ws() {
    echo ">>> Installation proxy WS via script sockspy.sh..."
    bash "$HOME/Kighmu/sockspy.sh" || echo "Script sockspy introuvable."
}

uninstall_proxy_ws() {
    echo ">>> Désinstallation proxy WS..."

    # Arrêt et suppression des processus existants
    PIDS=$(pgrep -f ws2_proxy.py || true)
    if [ -n "$PIDS" ]; then
        echo "Arrêt des processus proxy WS existants (PID: $PIDS)..."
        kill -15 $PIDS
        sleep 2
        PIDS=$(pgrep -f ws2_proxy.py || true)
        if [ -n "$PIDS" ]; then
            kill -9 $PIDS
        fi
    fi

    # Arrêt et suppression du service systemd
    if systemctl list-units --full -all | grep -Fq 'socks_python_ws.service'; then
        systemctl stop socks_python_ws.service || true
        systemctl disable socks_python_ws.service || true
        rm -f /etc/systemd/system/socks_python_ws.service
        systemctl daemon-reload
    fi

    # Suppression du script
    rm -f /usr/local/bin/ws2_proxy.py

    # Nettoyage de la table nftables sockspy
    nft delete table inet sockspy 2>/dev/null || true
    rm -f /etc/nftables/sockspy.nft
    systemctl disable --now nftables-tunnel@sockspy.service 2>/dev/null || true
    systemctl daemon-reload
    echo -e "${GREEN}[OK] Proxy WS désinstallé.${RESET}"
}

install_ssl_tls() {
    echo "🚀 Installation du tunnel SSL/TLS (ssl_tls)..."

    TMP_DIR="/tmp/ssl_tls_install"
    BIN_DST="/usr/local/bin/ssl_tls"
    URL_BIN="https://github.com/kinf744/Kighmu/releases/download/v1.0.0/ssl_tls"

    mkdir -p "$TMP_DIR" || return 1
    cd "$TMP_DIR" || return 1

    # Télécharger le binaire
    echo "📥 Téléchargement du binaire ssl_tls..."
    curl -fsSL "$URL_BIN" -o ssl_tls || {
        echo "[ERREUR] Téléchargement du binaire échoué"
        return 1
    }

    chmod +x ssl_tls

    # 🔕 SHA volontairement désactivé
    echo "⚠️ Vérification SHA-256 désactivée (mode temporaire)"

    # Vérifications minimales (important)
    file ssl_tls | grep -q ELF || {
        echo "[ERREUR] Le fichier téléchargé n'est pas un binaire valide"
        return 1
    }

    ./ssl_tls --help >/dev/null 2>&1 || {
        echo "[ERREUR] Le binaire ssl_tls ne s'exécute pas correctement"
        return 1
    }

    # Installer le binaire
    sudo install -m 0755 ssl_tls "$BIN_DST"
    echo "[OK] Binaire installé dans $BIN_DST"

    # Créer le service systemd
    SERVICE_FILE="/etc/systemd/system/ssl_tls.service"
    sudo tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Tunnel SSL/TLS (ssl_tls)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=$BIN_DST -listen 444 -target-host 127.0.0.1 -target-port 109
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now ssl_tls
    echo "[OK] Service systemd créé et démarré"

    # Ouvrir le port TCP 444 (table nftables dédiée)
    /usr/local/bin/init-nftables.sh

    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << 'EOF'
table inet ssl_tls {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 444 accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        tcp sport 444 accept
    }
}
EOF

    if nft -c -f "$TMP_NFT"; then
        mv "$TMP_NFT" /etc/nftables/ssl_tls.nft
        systemctl daemon-reload
        systemctl enable --now nftables-tunnel@ssl_tls.service
        systemctl restart nftables-tunnel@ssl_tls.service
        echo "[OK] Port TCP 444 autorisé (table nftables ssl_tls)"
    else
        echo "[ERREUR] Erreur de syntaxe nftables — table ssl_tls non appliquée"
        rm -f "$TMP_NFT"
    fi

    echo "[OK] Port TCP 444 autorisé"

    # Statut du service
    sudo systemctl status ssl_tls --no-pager

    # Nettoyage
    cd ~
    rm -rf "$TMP_DIR"
}

uninstall_ssl_tls() {
    echo "🧹 Désinstallation complète du tunnel SSL/TLS (ssl_tls)..."

    # Stopper et désactiver le service
    sudo systemctl stop ssl_tls 2>/dev/null || true
    sudo systemctl disable ssl_tls 2>/dev/null || true

    # Supprimer le fichier de service
    SERVICE_FILE="/etc/systemd/system/ssl_tls.service"
    [ -f "$SERVICE_FILE" ] && sudo rm -f "$SERVICE_FILE"

    sudo systemctl daemon-reload
    sudo systemctl reset-failed 2>/dev/null || true

    # Supprimer le binaire
    BIN_DST="/usr/local/bin/ssl_tls"
    [ -f "$BIN_DST" ] && sudo rm -f "$BIN_DST"

    nft delete table inet ssl_tls 2>/dev/null || true
    rm -f /etc/nftables/ssl_tls.nft
    systemctl disable --now nftables-tunnel@ssl_tls.service 2>/dev/null || true
    systemctl daemon-reload
    echo "[OK] Table nftables ssl_tls supprimée"

    echo "[OK] Tunnel SSL/TLS désinstallé proprement."
}

install_badvpn() {
    echo ">>> Installation BadVPN via script..."
    bash "$HOME/Kighmu/badvpn.sh" || echo "Script introuvable."
}

uninstall_badvpn() {
    echo ">>> Désinstallation complète BadVPN..."

    PORTS=(7100 7200 7300)

    # Arrêt et désactivation de chaque instance
    for PORT in "${PORTS[@]}"; do
        if systemctl list-units --full -all | grep -Fq "badvpn@${PORT}.service"; then
            echo "Arrêt et désactivation de badvpn@${PORT}.service..."
            systemctl stop "badvpn@${PORT}.service" || true
            systemctl disable "badvpn@${PORT}.service" || true
        fi
    done

    # Suppression du template systemd
    rm -f /etc/systemd/system/badvpn@.service
    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    # Suppression du binaire
    if [ -f "$BIN_PATH" ]; then
        echo "Suppression du binaire BadVPN..."
        rm -f "$BIN_PATH"
    fi

    # Nettoyage des règles nftables
    echo "Suppression des règles nftables pour les ports UDP ${PORTS[*]}..."
    nft delete table inet badvpn 2>/dev/null || true
    rm -f /etc/nftables/badvpn.nft
    systemctl disable --now nftables-tunnel@badvpn.service 2>/dev/null || true
    systemctl daemon-reload

    echo -e "${GREEN}[OK] BadVPN désinstallé (3 instances + table nftables).${RESET}"
}

HYST_PORT=22000

install_hysteria() {
    echo ">>> Installation du tunnel Hysteria 2 (UDP)..."

    # Vérification du fichier source
    if [ ! -f "$HOME/Kighmu/histeria2.go" ]; then
        echo "[ERREUR] histeria2.go introuvable dans $HOME/Kighmu"
        read -p "Appuyez sur Entrée..."
        return 1
    fi

    echo ">>> Compilation du binaire..."
    if ! go build -o /usr/local/bin/histeria2 "$HOME/Kighmu/histeria2.go"; then
        echo "[ERREUR] Échec de la compilation"
        read -p "Appuyez sur Entrée..."
        return 1
    fi

    chmod +x /usr/local/bin/histeria2
    echo "[OK] Binaire installé : /usr/local/bin/histeria2"

    echo ">>> Création du service systemd..."
    cat >/etc/systemd/system/histeria2.service <<EOF
[Unit]
Description=Hysteria 2 UDP Tunnel (Kighmu)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/histeria2
Restart=always
RestartSec=2
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable histeria2
    systemctl restart histeria2

    echo ">>> Ouverture du port UDP 22000..."
    /usr/local/bin/init-nftables.sh
    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << EOF
table inet histeria2 {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 22000 accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        udp sport 22000 accept
    }
}
EOF
    if nft -c -f "$TMP_NFT"; then
        mv "$TMP_NFT" /etc/nftables/histeria2.nft
        systemctl daemon-reload
        systemctl enable --now nftables-tunnel@histeria2.service
        systemctl restart nftables-tunnel@histeria2.service
        echo "[OK] Port UDP 22000 ouvert (table nftables histeria2)"
    else
        rm -f "$TMP_NFT"
    fi

    echo "[OK] Hysteria 2 installé et actif"
    systemctl status histeria2 --no-pager
    read -p "Appuyez sur Entrée..."
}

uninstall_hysteria() {
    echo ">>> Désinstallation du tunnel Hysteria 2..."

    systemctl stop histeria2 2>/dev/null || true
    systemctl disable histeria2 2>/dev/null || true

    rm -f /etc/systemd/system/histeria2.service
    rm -f /usr/local/bin/histeria2

    # Certificats TLS Hysteria (si utilisés)
    rm -rf /etc/ssl/histeria2
    rm -rf /var/log/histeria2

    systemctl daemon-reload

    echo ">>> Fermeture du port UDP 22000..."
    nft delete table inet histeria2 2>/dev/null || true
    rm -f /etc/nftables/histeria2.nft
    systemctl disable --now nftables-tunnel@histeria2.service 2>/dev/null || true
    systemctl daemon-reload

    echo "[OK] Hysteria 2 désinstallé proprement"
    read -p "Appuyez sur Entrée..."
}
    
# --- AJOUT WS/WSS SSH ---
install_sshws() {
    BIN_DST="/usr/local/bin/sshws"
    TMP_DIR="/tmp/sshws_install"
    RELEASE_URL="https://github.com/kinf744/Kighmu/releases/download/v1.0.0"

    # Préparer le dossier temporaire
    mkdir -p "$TMP_DIR"
    cd "$TMP_DIR" || return 1

    # Télécharger le binaire et le hash
    echo "⏳ Téléchargement de SSHWS..."
    curl -LO "$RELEASE_URL/sshws"
    curl -LO "$RELEASE_URL/sshws.sha256"

    # Vérifier l'intégrité
    echo "🔒 Vérification SHA-256..."
    sha256sum -c sshws.sha256 || {
        echo "❌ Vérification SHA-256 échouée"
        return 1
    }

    # Installer le binaire
    sudo install -m 0755 sshws "$BIN_DST"
    echo "✅ SSHWS installé dans $BIN_DST"

    # Firewall : table nftables dédiée
    /usr/local/bin/init-nftables.sh

    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << 'EOF'
table inet sshws {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 80 accept
    }
}
EOF

    if nft -c -f "$TMP_NFT"; then
        mv "$TMP_NFT" /etc/nftables/sshws.nft
        systemctl daemon-reload
        systemctl enable --now nftables-tunnel@sshws.service
        systemctl restart nftables-tunnel@sshws.service
        echo "✅ Port 80 ouvert (table nftables sshws)"
    else
        echo "❌ Erreur de syntaxe nftables — table sshws non appliquée"
        rm -f "$TMP_NFT"
    fi

    # systemd : création du service si absent
    SYSTEMD_FILE="/etc/systemd/system/sshws.service"
    if [ ! -f "$SYSTEMD_FILE" ]; then
        sudo tee "$SYSTEMD_FILE" >/dev/null <<EOF
[Unit]
Description=SSHWS Slipstream Tunnel
After=network.target

[Service]
Type=simple
ExecStart=$BIN_DST -listen 80 -target-host 127.0.0.1 -target-port 109
Restart=always
RestartSec=2
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now sshws
        echo "✅ Service systemd sshws installé et actif"
    else
        echo "ℹ️ Service systemd déjà existant, aucune modification effectuée"
    fi

    echo "🚀 SSHWS prêt à l'utilisation"

    # Nettoyage
    cd ~
    rm -rf "$TMP_DIR"
}

uninstall_sshws() {
    echo "🧹 Désinstallation complète de SSHWS..."

    if pgrep -f "/usr/local/bin/sshws" >/dev/null; then
        pkill -9 -f "/usr/local/bin/sshws"
        echo "💀 Tous les processus sshws ont été tués"
    else
        echo "ℹ️ Aucun processus sshws actif"
    fi

    if systemctl list-unit-files | grep -q "^sshws.service"; then
        systemctl stop sshws 2>/dev/null || true
        systemctl disable sshws 2>/dev/null || true
        echo "⛔ Service sshws arrêté et désactivé"
    fi

    if [ -f /etc/systemd/system/sshws.service ]; then
        rm -f /etc/systemd/system/sshws.service
        echo "🗑️ Service systemd supprimé"
    fi

    systemctl daemon-reload
    systemctl reset-failed 2>/dev/null || true

    [ -f /usr/local/bin/sshws ] && rm -f /usr/local/bin/sshws && echo "🗑️ Binaire sshws supprimé"
    [ -d /var/log/sshws ] && rm -rf /var/log/sshws && echo "🗑️ Logs sshws supprimés"

    nft delete table inet sshws 2>/dev/null || true
    rm -f /etc/nftables/sshws.nft
    systemctl disable --now nftables-tunnel@sshws.service 2>/dev/null || true
    systemctl daemon-reload
    echo "🔥 Table nftables sshws supprimée"

    if command -v screen >/dev/null 2>&1; then
        screen -ls | awk '/sshws/ {print $1}' | xargs -r -n1 screen -S {} -X quit
        echo "🧼 Sessions screen sshws nettoyées"
    fi

    echo "✅ SSHWS totalement désinstallé, système propre."
}

install_udp_request() {
    echo ">>> Installation udp_request via script udp_request.sh..."
    bash "$HOME/Kighmu/udp_request.sh" || echo "Script udp_request introuvable."
}

uninstall_udp_request() {
  print_title
  echo "[5] DÉSINSTALLATION udp_request (SAUF ZIVPN/Hysteria/SlowDNS)"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  # 1) Service seulement
  systemctl stop udp_request.service 2>/dev/null || true
  systemctl disable udp_request.service 2>/dev/null || true
  rm -f /etc/systemd/system/udp_request.service
  systemctl daemon-reload
  systemctl reset-failed udp_request.service 2>/dev/null || true

  # 2) Fichiers UDP-CUSTOM UNIQUEMENT
  rm -f /usr/local/bin/udp_request
  rm -rf /etc/udp_request
  rm -f /var/log/udp_request 2>/dev/null || true

  # 3) NFTABLES udp_request UNIQUEMENT
  nft delete table inet udp-request 2>/dev/null || true
  rm -f /etc/nftables/udp-request.nft
  systemctl disable --now nftables-tunnel@udp-request.service 2>/dev/null || true
  systemctl daemon-reload

  echo "✅ udp_request supprimé SANS toucher autres tunnels"
  pause
}

install_zivpn() {
    echo ">>> Installation Zivpn via script..."
    bash "$HOME/Kighmu/zivpn.sh" || echo "Script introuvable."
}

uninstall_zivpn() {
    echo "=== Désinstallation complète ZIVPN UDP ==="

    if systemctl list-unit-files | grep -q '^zivpn.service'; then
        systemctl stop zivpn.service >/dev/null 2>&1 || true
        systemctl disable zivpn.service >/dev/null 2>&1 || true
    fi

    if pgrep -f "/usr/local/bin/zivpn" >/dev/null 2>&1; then
        pkill -9 -f "/usr/local/bin/zivpn" || true
    fi

    rm -f /etc/systemd/system/zivpn.service
    systemctl daemon-reload >/dev/null 2>&1
    systemctl daemon-reexec >/dev/null 2>&1

    rm -f /usr/local/bin/zivpn
    rm -rf /etc/zivpn

    if nft list tables 2>/dev/null | grep -q 'inet zivpn'; then
        nft delete table inet zivpn >/dev/null 2>&1 || true
    fi

    rm -f /etc/nftables.d/zivpn.nft

    if [[ -f /etc/nftables.conf ]]; then
        sed -i '/\/etc\/nftables\.d\/\*\.nft/d' /etc/nftables.conf
    fi

    systemctl restart nftables >/dev/null 2>&1 || true

    rm -f /etc/sysctl.d/99-zivpn.conf
    sysctl --system >/dev/null 2>&1 || true

    if ip link show | grep -q tun; then
        ip link show | awk -F: '/tun/ {print $2}' | while read -r tun; do
            ip link del "$tun" >/dev/null 2>&1 || true
        done
    fi

    sed -i '/zivpn/d' /etc/kighmu/users.list 2>/dev/null || true

    echo "✅ ZIVPN totalement désinstallé"
}

# --- Interface utilisateur ---
manage_mode() {
    MODE_NAME=$1; INSTALL_FUNC=$2; UNINSTALL_FUNC=$3
    while true; do
        clear
        echo -e "${CYAN}+======================================================+${RESET}"
        echo -e "|          🚀 Gestion du mode : $MODE_NAME 🚀          |"
        echo -e "${CYAN}+======================================================+${RESET}"
        echo -e "${GREEN}${BOLD}[1]${RESET} ${YELLOW}Installer${RESET}"
        echo -e "${GREEN}${BOLD}[2]${RESET} ${YELLOW}Désinstaller${RESET}"
        echo -e "${GREEN}${BOLD}[0]${RESET} ${YELLOW}Retour${RESET}"
        echo -e "${CYAN}+======================================================+${RESET}"
        echo -ne "${BOLD}${YELLOW}👉 Choisissez une action : ${RESET}"
        read action
        case $action in
            1) $INSTALL_FUNC; read -p "Appuyez sur Entrée..." ;;
            2) $UNINSTALL_FUNC; read -p "Appuyez sur Entrée..." ;;
            0) break ;;
            *) echo -e "${RED}❌ Mauvais choix.${RESET}"; sleep 1 ;;
        esac
    done
}

while true; do
    clear
    HOST_IP=$(curl -s https://api.ipify.org)
    UPTIME=$(uptime -p)
    echo -e "${CYAN}+=====================================================+${RESET}"
    echo -e "|           🚀 PANNEAU DE CONTROLE DES MODES 🚀       |"
    echo -e "${CYAN}+=====================================================+${RESET}"
    echo -e "${CYAN} IP: ${GREEN}$HOST_IP${RESET} | ${CYAN}Up: ${GREEN}$UPTIME${RESET}"
    afficher_modes_ports
    echo -e "${CYAN}+======================================================+${RESET}"
    echo -e "${GREEN}${BOLD}[01]${RESET} ${YELLOW}OpenSSH${RESET}"
    echo -e "${GREEN}${BOLD}[02]${RESET} ${YELLOW}Dropbear${RESET}"
    echo -e "${GREEN}${BOLD}[03]${RESET} ${YELLOW}Fastdns (DNSTT)${RESET}"
    echo -e "${GREEN}${BOLD}[04]${RESET} ${YELLOW}UDP Custom${RESET}"
    echo -e "${GREEN}${BOLD}[05]${RESET} ${YELLOW}SOCKS/Python${RESET}"
    echo -e "${GREEN}${BOLD}[06]${RESET} ${YELLOW}SSL/TLS${RESET}"
    echo -e "${GREEN}${BOLD}[07]${RESET} ${YELLOW}BadVPN${RESET}"
    echo -e "${GREEN}${BOLD}[08]${RESET} ${YELLOW}proxy ws${RESET}"
    echo -e "${GREEN}${BOLD}[09]${RESET} ${YELLOW}Hysteria${RESET}"
    echo -e "${GREEN}${BOLD}[10]${RESET} ${YELLOW}Tunnel WS/WSS SSH${RESET}"
    echo -e "${GREEN}${BOLD}[11]${RESET} ${YELLOW}UDP_request${RESET}"
    echo -e "${GREEN}${BOLD}[00]${RESET} ${YELLOW}Quitter${RESET}"
    echo -e "${CYAN}+======================================================+${RESET}"
    echo -ne "${BOLD}${YELLOW}👉 Choisissez un mode : ${RESET}"
    read choix
    case $choix in
        1) manage_mode "OpenSSH" install_openssh uninstall_openssh ;;
        2) manage_mode "Dropbear" install_dropbear uninstall_dropbear ;;
        3) manage_mode "Fastdns (DNSTT)" install_slowdns uninstall_slowdns ;;
        4) manage_mode "UDP Custom" install_udp_custom uninstall_udp_custom ;;
        5) manage_mode "SOCKS/Python" install_socks_python uninstall_socks_python ;;
        6) manage_mode "SSL/TLS" install_ssl_tls uninstall_ssl_tls ;;
        7) manage_mode "BadVPN" install_badvpn uninstall_badvpn ;;
        8) manage_mode "proxy ws" install_proxy_ws uninstall_proxy_ws ;;
        9) manage_mode "Hysteria" install_hysteria uninstall_hysteria ;;
        10) manage_mode "Tunnel WS/WSS SSH" install_sshws uninstall_sshws ;;
        11) manage_mode "UDP_request" install_udp_request uninstall_udp_request ;;
        0) echo -e "${RED}🚪 Sortie du panneau de contrôle.${RESET}" ; exit 0 ;;
        *) echo -e "${RED}❌ Option invalide, réessayez.${RESET}" ;;
    esac
done
