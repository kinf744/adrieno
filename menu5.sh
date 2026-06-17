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
    if systemctl is-active --quiet slowdns.service || pgrep -f "sldns-server" >/dev/null 2>&1 || screen -list | grep -q slowdns_session; then any_active=1; fi
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
    if systemctl is-active --quiet slowdns.service || pgrep -f "sldns-server" >/dev/null 2>&1 || screen -list | grep -q slowdns_session; then
        echo -e "  - SlowDNS: ${GREEN}ports UDP 5300${RESET}"
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
    echo ">>> Nettoyage avant installation SlowDNS..."
    pkill -f slowdns || true
    rm -rf "$HOME/.slowdns"
    rm -f /usr/local/bin/slowdns
    systemctl stop slowdns.service 2>/dev/null || true
    systemctl disable slowdns.service 2>/dev/null || true
    rm -f /etc/systemd/system/slowdns.service
    systemctl daemon-reload

    # Suppression règles iptables port 5300
    iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
    iptables -D INPUT -p tcp --dport 5300 -j ACCEPT 2>/dev/null || true
    # Suppression table nftables slowdns si elle existe
    nft delete table ip slowdns 2>/dev/null || true
    netfilter-persistent save 2>/dev/null || true

    echo ">>> Installation/configuration SlowDNS..."
    bash "$HOME/Kighmu/slowdns.sh" || echo "SlowDNS : script introuvable."
}

uninstall_slowdns() {
  print_title
  echo "[5] DÉSINSTALLATION SLOWDNS (SAUF ZIVPN/Hysteria)"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  # 1) Service seulement
  systemctl stop slowdns.service 2>/dev/null || true
  systemctl disable slowdns.service 2>/dev/null || true
  rm -f /etc/systemd/system/slowdns.service
  systemctl daemon-reload

  # 2) Processus + fichiers
  pkill -15 -f dnstt-server 2>/dev/null || true
  pkill -15 -f slowdns-start.sh 2>/dev/null || true
  sleep 2
  pkill -9 -f dnstt-server 2>/dev/null || true
  pkill -9 -f slowdns-start.sh 2>/dev/null || true

  rm -f /usr/local/bin/dnstt-server /usr/local/bin/slowdns-start.sh
  rm -rf /etc/slowdns
  rm -f /var/log/slowdns.log

  # 3) Nettoyage firewall SlowDNS
  iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
  iptables -D INPUT -p tcp --dport 5300 -j ACCEPT 2>/dev/null || true
  # Supprimer table nftables isolée — sans toucher ZIVPN/Hysteria
  nft delete table ip slowdns 2>/dev/null || true
  netfilter-persistent save 2>/dev/null || true

  echo "✅ SlowDNS supprimé SANS toucher ZIVPN/Hysteria"
  echo "   Vérifiez: nft list tables"
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

  # 3) IPTABLES UDP-CUSTOM UNIQUEMENT (EXACT match installation)
  iptables -D INPUT -p udp --dport 36712 -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 36712 -j DNAT --to-destination :36712 2>/dev/null || true

  # ✅ SAUVEGARDE iptables (AUTRES tunnels préservés)
  netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

  echo "✅ UDP-Custom supprimé SANS toucher autres tunnels"
  echo "   Vérifiez: iptables -L INPUT -n | grep 36712"
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

    # Suppression des règles iptables persistantes pour les ports 8080 et 9090
    for port in 8080 9090; do
        iptables -D INPUT -p tcp --dport $port -j ACCEPT 2>/dev/null || true
    done
    iptables-save | tee /etc/iptables/rules.v4
    systemctl restart netfilter-persistent

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

    # Nettoyage des règles iptables seulement
    iptables -D INPUT -p tcp --dport 9090 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p tcp --sport 9090 -j ACCEPT 2>/dev/null || true

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

    # Ouvrir le port TCP 444 (iptables)
    sudo iptables -C INPUT -p tcp --dport 444 -j ACCEPT 2>/dev/null || \
        sudo iptables -I INPUT -p tcp --dport 444 -j ACCEPT

    sudo iptables -C OUTPUT -p tcp --sport 444 -j ACCEPT 2>/dev/null || \
        sudo iptables -I OUTPUT -p tcp --sport 444 -j ACCEPT

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

    # Supprimer les règles iptables
    for PORT in 444; do
        while sudo iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
            sudo iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT
        done
        while sudo iptables -C OUTPUT -p tcp --sport "$PORT" -j ACCEPT 2>/dev/null; do
            sudo iptables -D OUTPUT -p tcp --sport "$PORT" -j ACCEPT
        done
    done

    echo "[OK] Tunnel SSL/TLS désinstallé proprement."
}

install_badvpn() {
    echo ">>> Installation BadVPN via script..."
    bash "$HOME/Kighmu/badvpn.sh" || echo "Script introuvable."
}

uninstall_badvpn() {
    echo ">>> Désinstallation complète BadVPN..."

    # Arrêt et suppression du service systemd
    if systemctl list-units --full -all | grep -Fq 'badvpn.service'; then
        echo "Arrêt et désactivation du service badvpn.service..."
        systemctl stop badvpn.service || true
        systemctl disable badvpn.service || true
        rm -f "$SYSTEMD_UNIT"
        systemctl daemon-reload
    fi

    # Suppression du binaire
    if [ -f "$BIN_PATH" ]; then
        echo "Suppression du binaire BadVPN..."
        rm -f "$BIN_PATH"
    fi

    # Nettoyage des règles iptables persistantes pour le port
    echo "Suppression des règles iptables pour le port UDP $PORT..."
    iptables -D INPUT -p udp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport "$PORT" -j ACCEPT 2>/dev/null || true
    iptables-save | tee /etc/iptables/rules.v4
    systemctl restart netfilter-persistent || true

    echo -e "${GREEN}[OK] BadVPN désinstallé.${RESET}"
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
    iptables -I INPUT  -p udp --dport 22000 -j ACCEPT
    iptables -I OUTPUT -p udp --sport 22000 -j ACCEPT

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
    iptables -D INPUT  -p udp --dport 22000 -j ACCEPT 2>/dev/null || true
    iptables -D OUTPUT -p udp --sport 22000 -j ACCEPT 2>/dev/null || true

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

    # Firewall : ouvrir le port 80 si iptables disponible
    if command -v iptables >/dev/null 2>&1; then
        if ! sudo iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null; then
            sudo iptables -I INPUT -p tcp --dport 80 -j ACCEPT
            command -v netfilter-persistent >/dev/null && sudo netfilter-persistent save
            echo "✅ Port 80 ouvert dans le firewall"
        fi
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

    for PORT in 80 88 8080; do
        while iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; do
            iptables -D INPUT -p tcp --dport "$PORT" -j ACCEPT
            echo "🔥 Règle iptables supprimée pour le port $PORT"
        done
    done

    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >/dev/null 2>&1
        echo "💾 Règles iptables sauvegardées"
    fi

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

  # 3) IPTABLES udp_request UNIQUEMENT (EXACT match installation)
  iptables -D INPUT -p udp --dport 4466 -j ACCEPT 2>/dev/null || true
  iptables -t nat -D PREROUTING -p udp --dport 4466 -j DNAT --to-destination :4466 2>/dev/null || true

  # ✅ SAUVEGARDE iptables (AUTRES tunnels préservés)
  netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4

  echo "✅ udp_request supprimé SANS toucher autres tunnels"
  echo "   Vérifiez: iptables -L INPUT -n | grep 4466"
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
