#!/bin/bash
# socks_python.sh
# Gestion dynamique du port SOCKS, nettoyage complet du config, installation pysocks, nftables et systemd

set -euo pipefail

echo "+--------------------------------------------+"
echo "|             CONFIG SOCKS/PYTHON            |"
echo "+--------------------------------------------+"

# Variables globales
CONF_DIR="/etc/socks_python"
SCRIPT_PATH="/usr/local/bin/KIGHMUPROXY.py"
SCRIPT_URL="https://raw.githubusercontent.com/kinf744/Kighmu/main/KIGHMUPROXY.py"
LOG_FILE="/var/log/socks_python.log"
CONFIG_PORT_FILE="$CONF_DIR/socks_port.conf"

# Création du dossier config si nécessaire
sudo mkdir -p "$CONF_DIR"
sudo chown "$USER":"$USER" "$CONF_DIR"

ask_port() {
  local port_input=""
  while true; do
    read -e -p "Saisissez le port SOCKS (1024-65535) : " port_input
    if [[ "$port_input" =~ ^[0-9]+$ ]] && [ "$port_input" -ge 1024 ] && [ "$port_input" -le 65535 ]; then
      echo "$port_input"
      return
    else
      echo "Port invalide. Saisissez un nombre entre 1024 et 65535."
    fi
  done
}

cleanup_port() {
  local port=$1
  echo "Nettoyage complet du port $port..."

  # Tuer processus
  local PIDS
  PIDS=$(sudo lsof -ti :$port 2>/dev/null || true)
  [ -n "$PIDS" ] && sudo kill -9 $PIDS || true

  # Stop et disable systemd
  if systemctl list-units --full -all | grep -q "socks_python.service"; then
    sudo systemctl stop socks_python.service || true
    sudo systemctl disable socks_python.service || true
    sudo systemctl daemon-reload
  fi

  # Supprimer table nftables existante
  nft delete table inet socks-python 2>/dev/null || true
  rm -f /etc/nftables/socks-python.nft
  systemctl disable --now nftables-tunnel@socks-python.service 2>/dev/null || true

  # Vérification port
  if sudo lsof -ti :$port >/dev/null 2>&1; then
    echo "Port $port encore occupé après nettoyage."
    return 1
  else
    echo "Port $port libre."
    return 0
  fi
}

install_pysocks() {
  echo "Installation du module Python pysocks..."
  if sudo apt-get update -y && sudo apt-get install -y python3-socks; then
    echo "Module pysocks installé via apt."
    return 0
  fi

  # fallback venv
  [[ ! -d "$HOME/socksenv" ]] && python3 -m venv "$HOME/socksenv"
  source "$HOME/socksenv/bin/activate"
  pip install --upgrade pip setuptools
  pip install pysocks
  deactivate
  echo "Module pysocks installé dans l'environnement virtuel $HOME/socksenv."
}

create_systemd_service() {
  local port=$1
  SERVICE_PATH="/etc/systemd/system/socks_python.service"
  sudo tee "$SERVICE_PATH" > /dev/null <<EOF
[Unit]
Description=Proxy SOCKS Python
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 $SCRIPT_PATH $port
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=socks-python-proxy

[Install]
WantedBy=multi-user.target
EOF

  sudo systemctl daemon-reload
  sudo systemctl enable socks_python.service
  sudo systemctl restart socks_python.service
  echo "Service socks_python activé et démarré."
}

read -p "Voulez-vous démarrer le proxy SOCKS/Python ? [oui/non] : " confirm

case "$confirm" in
  [oO][uU][iI]|[yY][eE][sS])
    PROXY_PORT="$(ask_port)"
    sudo rm -f "$CONFIG_PORT_FILE"
    echo "$PROXY_PORT" | sudo tee "$CONFIG_PORT_FILE" > /dev/null

    cleanup_port "$PROXY_PORT" || { echo "Échec nettoyage port. Abandon."; exit 1; }

    # Installation pysocks si nécessaire
    if ! python3 -c "import socks" &>/dev/null; then
      install_pysocks || { echo "Échec installation pysocks."; exit 1; }
    fi

    # Téléchargement du script proxy
    if [ ! -f "$SCRIPT_PATH" ]; then
      sudo mkdir -p "$(dirname "$SCRIPT_PATH")"
      sudo wget -q -O "$SCRIPT_PATH" "$SCRIPT_URL" || { echo "Échec téléchargement script."; exit 1; }
      sudo chmod +x "$SCRIPT_PATH"
    fi

    # Arrêt instances précédentes
    PIDS=$(pgrep -f "python3 $SCRIPT_PATH" || true)
    [ -n "$PIDS" ] && sudo kill -9 $PIDS && sleep 2

    # Ouverture port avec nftables (table dédiée)
    /usr/local/bin/init-nftables.sh
    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << EOF
table inet socks-python {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport $PROXY_PORT accept
    }
}
EOF
    if nft -c -f "$TMP_NFT"; then
        sudo mv "$TMP_NFT" /etc/nftables/socks-python.nft
        sudo systemctl daemon-reload
        sudo systemctl enable --now nftables-tunnel@socks-python.service
        sudo systemctl restart nftables-tunnel@socks-python.service
        echo "✅ Port $PROXY_PORT autorisé (table nftables socks-python)"
    else
        echo "❌ Erreur de syntaxe nftables"
        rm -f "$TMP_NFT"
    fi

    # Démarrage du proxy
    nohup sudo python3 "$SCRIPT_PATH" "$PROXY_PORT" > "$LOG_FILE" 2>&1 &
    sleep 3

    if pgrep -f "python3 $SCRIPT_PATH" >/dev/null; then
      echo "Proxy SOCKS/Python démarré sur le port $PROXY_PORT."
      create_systemd_service "$PROXY_PORT"
    else
      echo "Échec démarrage proxy. Vérifiez $LOG_FILE."
    fi
    ;;
  [nN][oO]|[nN])
    echo "Démarrage annulé."
    ;;
  *)
    echo "Réponse invalide. Abandon."
    ;;
esac
