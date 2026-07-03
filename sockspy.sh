#!/bin/bash
# sockspy.sh
# Installation / activation du proxy SOCKS Python WebSocket via systemd avec persistance SlowDNS-style

set -euo pipefail

echo "+--------------------------------------------+"
echo "|        CONFIG SOCKS/PYTHON WS              |"
echo "+--------------------------------------------+"

# Port par défaut
DEFAULT_PORT=9090
PORT=${2:-$DEFAULT_PORT}
CONF_DIR="/etc/sockspy"
SCRIPT_PATH="/usr/local/bin/ws2_proxy.py"
SCRIPT_URL="https://raw.githubusercontent.com/kinf744/Kighmu/main/ws2_proxy.py"
SYSTEMD_SERVICE="/etc/systemd/system/socks_python_ws.service"
ENV_FILE="$CONF_DIR/sockspy.env"
LOG_FILE="/var/log/sockspy.log"

mkdir -p "$CONF_DIR"

# Fonction de log
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# Vérification module pysocks
install_pysocks() {
    log "Installation du module Python pysocks..."
    if ! python3 -c "import socks" &>/dev/null; then
        if ! apt-get install -y python3-socks; then
            apt-get install -y python3-venv
            VENV_DIR="$HOME/socksenv"
            python3 -m venv "$VENV_DIR"
            source "$VENV_DIR/bin/activate"
            pip install --upgrade pip setuptools
            pip install pysocks
            deactivate
        fi
    fi
    log "Module pysocks installé."
}

# Nettoyage port et anciens processus
cleanup_port() {
    local port="$1"
    log "Nettoyage du port $port..."
    PIDS=$(pgrep -f "ws2_proxy.py" || true)
    if [ -n "$PIDS" ]; then
        log "Arrêt des processus existants : $PIDS"
        kill -9 $PIDS
        sleep 2
    fi
    # Vérifier si le port est encore occupé
    if lsof -ti tcp:"$port" &>/dev/null; then
        log "Port $port encore utilisé après nettoyage."
        exit 1
    fi
}

# Téléchargement du script
download_script() {
    if [ ! -f "$SCRIPT_PATH" ] || [ $(( $(date +%s) - $(stat -c %Y "$SCRIPT_PATH") )) -ge 86400 ]; then
        log "Téléchargement / mise à jour du script proxy..."
        wget -q -O "$SCRIPT_PATH" "$SCRIPT_URL"
        chmod +x "$SCRIPT_PATH"
    fi
    log "Script proxy prêt : $SCRIPT_PATH"
}

# Création du service systemd avec persistance SlowDNS-style
create_systemd_service() {
    cat <<EOF > "$SYSTEMD_SERVICE"
[Unit]
Description=Proxy SOCKS/Python WS
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=$SCRIPT_PATH $PORT
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=sockspy
LimitNOFILE=1048576
Nice=-5
CPUSchedulingPolicy=fifo
CPUSchedulingPriority=99

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable socks_python_ws.service
    systemctl restart socks_python_ws.service
    log "Service systemd socks_python_ws démarré et activé pour persistance."
}

# Configuration nftables persistante
configure_nftables() {
    log "Configuration nftables pour le port $PORT..."
    /usr/local/bin/init-nftables.sh
    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << EOF
table inet sockspy {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport $PORT accept
    }
}
EOF
    if nft -c -f "$TMP_NFT"; then
        mv "$TMP_NFT" /etc/nftables/sockspy.nft
        systemctl daemon-reload
        systemctl enable --now nftables-tunnel@sockspy.service
        systemctl restart nftables-tunnel@sockspy.service
        log "✅ Table nftables sockspy chargée et persistée"
    else
        log "❌ Erreur de syntaxe nftables — table sockspy non appliquée"
        rm -f "$TMP_NFT"
    fi
}

# Génération du fichier .env
create_env_file() {
    log "Création du fichier de configuration $ENV_FILE..."
    cat <<EOF > "$ENV_FILE"
PORT=$PORT
SCRIPT_PATH=$SCRIPT_PATH
SYSTEMD_SERVICE=$SYSTEMD_SERVICE
EOF
    chmod 600 "$ENV_FILE"
    log "Fichier .env généré."
}

# Démarrage principal
main() {
    if [ "${1:-}" != "auto" ]; then
        read -p "Voulez-vous démarrer le proxy SOCKS/Python WS sur le port $PORT ? [oui/non] : " confirm
    else
        confirm="oui"
    fi

    case "$confirm" in
        [oO][uU][iI]|[yY][eE][sS])
            install_pysocks
            cleanup_port "$PORT"
            download_script
            configure_nftables
            create_systemd_service
            create_env_file
            log "Installation et configuration terminées. Vérifiez les logs : $LOG_FILE"
            ;;
        *)
            log "Installation annulée."
            exit 0
            ;;
    esac
}

main "$@"
