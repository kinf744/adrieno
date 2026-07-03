#!/bin/bash
# badvpn.sh - Installation complète de BadVPN-UDPGW (3 instances) depuis les sources officielles
# Auteur: kinf744 (2025) - Licence MIT

set -euo pipefail

# Couleurs
RED="\e[1;31m"
GREEN="\e[1;32m"
CYAN="\e[1;36m"
RESET="\e[0m"

# Vérification privilèges root
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}Ce script doit être exécuté en tant que root.${RESET}"
  exit 1
fi

# Config
BIN_PATH="/usr/local/bin/badvpn-udpgw"
SRC_REPO="https://github.com/ambrop72/badvpn.git"
SRC_DIR="/tmp/badvpn-src"
LISTEN_ADDR="127.0.0.1"
PORTS=(7100 7200 7300)
LOG_DIR="/var/log/badvpn"
LOG_FILE="$LOG_DIR/install.log"

mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "+--------------------------------------------+"
echo "|             DÉBUT D'INSTALLATION           |"
echo "+--------------------------------------------+"

# ==== Dépendances de compilation ====
echo "Installation des dépendances de compilation..."
apt-get update -qq
apt-get install -y -qq git cmake build-essential

# ==== Compilation depuis la source officielle ====
if [ ! -x "$BIN_PATH" ]; then
  echo "Clonage du dépôt officiel BadVPN..."
  rm -rf "$SRC_DIR"
  git clone --depth 1 "$SRC_REPO" "$SRC_DIR" || {
    echo -e "${RED}Échec du clonage du dépôt officiel.${RESET}"
    exit 1
  }

  mkdir -p "$SRC_DIR/build"
  cd "$SRC_DIR/build"

  echo "Compilation de badvpn-udpgw..."
  cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 || {
    echo -e "${RED}Échec de la configuration cmake.${RESET}"
    exit 1
  }
  make -j"$(nproc)" || {
    echo -e "${RED}Échec de la compilation.${RESET}"
    exit 1
  }

  if [ ! -f "udpgw/badvpn-udpgw" ]; then
    echo -e "${RED}Binaire compilé introuvable après build.${RESET}"
    exit 1
  fi

  install -m 0755 udpgw/badvpn-udpgw "$BIN_PATH"
  cd /
  rm -rf "$SRC_DIR"

  # Vérification finale : binaire ELF valide et exécutable
  if ! file "$BIN_PATH" | grep -q ELF; then
    echo -e "${RED}Erreur : le binaire compilé n'est pas valide.${RESET}"
    rm -f "$BIN_PATH"
    exit 1
  fi
  echo -e "${GREEN}Binaire compilé et installé avec succès dans $BIN_PATH${RESET}"
else
  echo -e "${GREEN}BadVPN déjà installé sur $BIN_PATH.${RESET}"
fi

# Arrêter toute instance existante
pkill -f badvpn-udpgw 2>/dev/null || true
sleep 1

# ==== Service systemd template (une instance par port) ====
cat > /etc/systemd/system/badvpn.service <<EOF
[Unit]
Description=BadVPN UDP Gateway (port %i)
After=network.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH --listen-addr $LISTEN_ADDR:%i --max-clients 1000 --max-connections-for-client 10
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=badvpn-%i
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload

FAILED=0
for PORT in "${PORTS[@]}"; do
  systemctl enable --now "badvpn@${PORT}.service"
  sleep 1
  if systemctl is-active --quiet "badvpn@${PORT}.service"; then
    echo -e "${GREEN}badvpn@${PORT} actif${RESET}"
  else
    echo -e "${RED}badvpn@${PORT} a échoué${RESET}"
    FAILED=1
  fi
done

# ==== Ouverture des ports UDP via nftables (table dédiée) ====
/usr/local/bin/init-nftables.sh

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << EOF
table inet badvpn {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport { ${PORTS[0]}, ${PORTS[1]}, ${PORTS[2]} } accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        tcp sport { ${PORTS[0]}, ${PORTS[1]}, ${PORTS[2]} } accept
    }
}
EOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/badvpn.nft
    systemctl daemon-reload
    systemctl enable --now nftables-tunnel@badvpn.service
    systemctl restart nftables-tunnel@badvpn.service
    echo -e "${GREEN}Table nftables badvpn chargée et persistée${RESET}"
else
    echo -e "${RED}Erreur de syntaxe nftables — table badvpn non appliquée${RESET}"
    rm -f "$TMP_NFT"
    exit 1
fi

# ==== Vérification finale ====
if [ "$FAILED" -eq 0 ]; then
  echo "+--------------------------------------------+"
  echo "|           INSTALLATION RÉUSSIE             |"
  echo "+--------------------------------------------+"
else
  echo -e "${RED}Une ou plusieurs instances BadVPN n'ont pas démarré.${RESET}"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] INSTALL_PARTIAL_FAILURE" >> "$LOG_FILE"
fi

# Résumé final
echo -e "\n${CYAN}Résumé d'installation :${RESET}"
echo "  ➤ Binaire     : $BIN_PATH (compilé depuis les sources officielles)"
echo "  ➤ Ports UDP   : ${PORTS[*]}"
echo "  ➤ Écoute sur  : $LISTEN_ADDR"
echo "  ➤ Services    : badvpn@7100, badvpn@7200, badvpn@7300"
echo "  ➤ Table nftables : badvpn (/etc/nftables/badvpn.nft)"
echo "  ➤ Logs        : $LOG_FILE"
echo -e "\nInstallation terminée."
