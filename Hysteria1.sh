#!/bin/bash
# Hysteria1.sh - Aligné sur arivpnstores/udp-zivpn
# CORRIGÉ: set -e supprimé, StartLimitIntervalSec ajouté, JSON sécurisé

HYSTERIA_BIN="/usr/local/bin/hysteria-linux-amd64"
HYSTERIA_SERVICE="hysteria.service"
HYSTERIA_CONFIG="/etc/hysteria/config.json"
HYSTERIA_USER_FILE="/etc/hysteria/users.txt"
HYSTERIA_DOMAIN_FILE="/etc/hysteria/domain.txt"

# ==========================================================
setup_colors() {
    RED=""; GREEN=""; YELLOW=""; CYAN=""; WHITE=""
    MAGENTA=""; MAGENTA_VIF=""; BOLD=""; RESET=""
    if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
        RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
        MAGENTA="$(tput setaf 5)"; MAGENTA_VIF="$(tput setaf 5; tput bold)"
        CYAN="$(tput setaf 6)"; WHITE="$(tput setaf 7)"
        BOLD="$(tput bold)"; RESET="$(tput sgr0)"
    fi
}

setup_colors

pause() {
  echo
  read -rp "Appuyez sur Entrée pour continuer..."
}

check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Ce panneau doit être lancé en root."
    exit 1
  fi
}

hysteria_installed() {
  [[ -x "$HYSTERIA_BIN" ]] && systemctl list-unit-files | grep -q "^$HYSTERIA_SERVICE"
}

hysteria_running() {
  systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null
}

print_title() {
  clear
  echo "${CYAN}${BOLD}╔═══════════════════════════════════════╗${RESET}"
  echo "${CYAN}║        HYSTERIA CONTROL PANEL v1      ║${RESET}"
  echo "${CYAN}║     (Compatible @kighmu 🇨🇲)           ║${RESET}"
  echo "${CYAN}${BOLD}╚═══════════════════════════════════════╝${RESET}"
  echo
}

show_status_block() {
  echo "${CYAN}-------------- STATUT HYSTERIA --------------${RESET}"
  local SVC_FILE_OK SVC_ACTIVE PORT_OK ACTIVE_USERS TODAY
  SVC_FILE_OK=$([[ -f "/etc/systemd/system/$HYSTERIA_SERVICE" ]] && echo "✅" || echo "❌")
  SVC_ACTIVE=$(systemctl is-active "$HYSTERIA_SERVICE" 2>/dev/null || echo "inactif")
  PORT_OK=$(ss -lunp 2>/dev/null | grep -q ":20000" && echo "✅" || echo "❌")
  echo "${WHITE}Service file:${RESET} $SVC_FILE_OK"
  echo "${WHITE}Service actif:${RESET} $SVC_ACTIVE"
  echo "${WHITE}Port 20000:${RESET} $PORT_OK"
  if [[ -f "$HYSTERIA_USER_FILE" ]]; then
    TODAY=$(date +%Y-%m-%d)
    ACTIVE_USERS=$(awk -F'|' -v today="$TODAY" '$3>=today {count++} END{print count+0}' "$HYSTERIA_USER_FILE")
  else
    ACTIVE_USERS=0
  fi
  echo "${CYAN}Utilisateurs actifs:${RESET} $ACTIVE_USERS"
  if [[ "$SVC_FILE_OK" == "✅" ]]; then
    if systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null; then
      echo "${GREEN}✅ HYSTERIA : INSTALLÉ et ACTIF${RESET}"
    else
      echo "⚠️  HYSTERIA : INSTALLÉ mais INACTIF"
    fi
  else
    echo "${RED}❌ HYSTERIA : NON INSTALLÉ${RESET}"
  fi
  echo "${CYAN}------------------------------------------${RESET}"
  echo
}

# ---------- Mise à jour sécurisée du JSON ----------
# CORRECTION: Si aucun utilisateur actif, garder au moins un password vide
# pour éviter un JSON invalide qui casse le service
update_hysteria_config_passwords() {
  local TODAY
  TODAY=$(date +%Y-%m-%d)
  local PASSWORDS
  PASSWORDS=$(awk -F'|' -v today="$TODAY" '$3>=today {print $2}' "$HYSTERIA_USER_FILE" 2>/dev/null | sort -u | paste -sd, -)

  # Si aucun mot de passe actif, garder config inchangée
  if [[ -z "$PASSWORDS" ]]; then
    echo "⚠️  Aucun utilisateur actif - config inchangée"
    return 0
  fi

  local TMP
  TMP=$(mktemp)
  if jq --arg passwords "$PASSWORDS" \
        '.auth.config = ($passwords | split(","))' \
        "$HYSTERIA_CONFIG" > "$TMP" 2>/dev/null && \
     jq empty "$TMP" >/dev/null 2>&1; then
    mv "$TMP" "$HYSTERIA_CONFIG"
    systemctl restart "$HYSTERIA_SERVICE" || true
    return 0
  else
    echo "${RED}❌ JSON invalide → config inchangée${RESET}"
    rm -f "$TMP"
    return 1
  fi
}

# ---------- 1) Installation ----------
install_hysteria() {
  print_title
  echo "[1] INSTALLATION HYSTERIA"
  echo

  if hysteria_installed; then
    echo "HYSTERIA déjà installé."
    pause; return
  fi

  systemctl stop hysteria 2>/dev/null || true
  systemctl stop ufw 2>/dev/null || true
  ufw disable 2>/dev/null || true
  apt purge ufw -y 2>/dev/null || true
  apt update -y && apt install -y wget curl jq openssl

  wget -q "https://github.com/apernet/hysteria/releases/download/v1.3.4/hysteria-linux-amd64" -O "$HYSTERIA_BIN"
  chmod +x "$HYSTERIA_BIN"

  mkdir -p /etc/hysteria
  read -rp "Domaine: " DOMAIN; DOMAIN=${DOMAIN:-"hysteria.local"}
  echo "$DOMAIN" > "$HYSTERIA_DOMAIN_FILE"

  local CERT="/etc/hysteria/hysteria.crt" KEY="/etc/hysteria/hysteria.key"
  openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -nodes -days 3650 -subj "/CN=$DOMAIN"
  chmod 600 "$KEY"; chmod 644 "$CERT"

  cat > "$HYSTERIA_CONFIG" << 'EOF'
{
  "listen": ":20000",
  "cert": "/etc/hysteria/hysteria.crt",
  "key": "/etc/hysteria/hysteria.key",
  "obfs": "hysteria",
  "up_mbps": 150,
  "down_mbps": 150,
  "recv_window_conn": 33554432,
  "recv_window_client": 8388608,
  "disable_mtu_discovery": false,
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF

  # CORRECTION: StartLimitIntervalSec et StartLimitBurst pour éviter start-limit-hit
  cat > "/etc/systemd/system/$HYSTERIA_SERVICE" << EOF
[Unit]
Description=HYSTERIA UDP Server
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$HYSTERIA_BIN server -c $HYSTERIA_CONFIG
WorkingDirectory=/etc/hysteria
Restart=always
RestartSec=5
StartLimitBurst=0
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
StandardOutput=append:/var/log/hysteria.log
StandardError=append:/var/log/hysteria.log

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload && systemctl enable "$HYSTERIA_SERVICE"

  /usr/local/bin/init-nftables.sh

  nft delete table inet hysteria 2>/dev/null || true

  nft -f - << EOF
table inet hysteria {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 20000 accept
        udp dport 20000-50000 accept
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        udp dport 20000-50000 dnat to :20000
    }
}
EOF

  nft list table inet hysteria > /etc/nftables/hysteria.nft
  systemctl reload nftables 2>/dev/null || systemctl restart nftables
  
  sysctl -w net.core.rmem_max=16777216 2>/dev/null || true
  sysctl -w net.core.wmem_max=16777216 2>/dev/null || true
  grep -q "rmem_max=16777216" /etc/sysctl.conf || echo "net.core.rmem_max=16777216" >> /etc/sysctl.conf
  grep -q "wmem_max=16777216" /etc/sysctl.conf || echo "net.core.wmem_max=16777216" >> /etc/sysctl.conf

  systemctl start "$HYSTERIA_SERVICE" || true
  sleep 3

  if systemctl is-active --quiet "$HYSTERIA_SERVICE"; then
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo "✅ HYSTERIA installé et actif !"
    echo "📱 Config:"
    echo "   Serveur: $IP"
    echo "   Port: 20000-50000"
    echo "   Password: zi"
    echo "   Obfs: hysteria"
  else
    echo "❌ HYSTERIA ne démarre pas"
    journalctl -u hysteria.service -n 20 --no-pager
  fi
  pause
}

# ---------- 2) Création utilisateur ----------
create_hysteria_user() {
  print_title
  echo "${MAGENTA_VIF}[2] CRÉATION UTILISATEUR HYSTERIA${RESET}"

  if ! systemctl is-active --quiet "$HYSTERIA_SERVICE" 2>/dev/null; then
    echo "❌ Service HYSTERIA inactif. Lance l'option 1."
    pause; return
  fi

  read -rp "Téléphone: " PHONE
  [[ -z "$PHONE" ]] && { echo "❌ Téléphone vide"; pause; return; }
  read -rp "Password HYSTERIA: " PASS
  [[ -z "$PASS" ]] && { echo "❌ Password vide"; pause; return; }
  read -rp "Durée (jours): " DAYS
  [[ ! "$DAYS" =~ ^[0-9]+$ ]] && { echo "❌ Durée invalide"; pause; return; }

  local EXPIRE
  EXPIRE=$(date -d "+${DAYS} days" '+%Y-%m-%d')

  local TMP
  TMP=$(mktemp)
  grep -v "^$PHONE|" "$HYSTERIA_USER_FILE" > "$TMP" 2>/dev/null || true
  echo "$PHONE|$PASS|$EXPIRE" >> "$TMP"
  mv "$TMP" "$HYSTERIA_USER_FILE"
  chmod 600 "$HYSTERIA_USER_FILE"

  if update_hysteria_config_passwords; then
    local IP DOMAIN
    IP=$(hostname -I | awk '{print $1}')
    DOMAIN=$(cat "$HYSTERIA_DOMAIN_FILE" 2>/dev/null || echo "$IP")
    echo
    echo "${MAGENTA}✅ UTILISATEUR CRÉÉ${RESET}"
    echo "${CYAN}━━━━━━━━━━━━━━━━━━━━━${RESET}"
    echo "🌐 Domaine  : $DOMAIN"
    echo "🎭 Obfs     : hysteria"
    echo "🔐 Password : $PASS"
    echo "📅 Expire   : $EXPIRE"
    echo "🔌 Port     : 20000-50000"
    echo "${CYAN}━━━━━━━━━━━━━━━━━━━━━${RESET}"
  fi
  pause
}

# ---------- 3) Suppression utilisateur ----------
delete_hysteria_user() {
  print_title
  echo "${MAGENTA_VIF}[3] SUPPRIMER UTILISATEUR${RESET}"

  if [[ ! -f "$HYSTERIA_USER_FILE" || ! -s "$HYSTERIA_USER_FILE" ]]; then
    echo "❌ Aucun utilisateur enregistré."
    pause; return
  fi

  mapfile -t USERS < <(sort -t'|' -k3 "$HYSTERIA_USER_FILE")
  echo "Utilisateurs (sélectionnez NUMÉRO):"
  echo "${CYAN}────────────────────────────────────${RESET}"
  for i in "${!USERS[@]}"; do
    local UNAME EXP
    UNAME=$(echo "${USERS[$i]}" | cut -d'|' -f1)
    EXP=$(echo "${USERS[$i]}" | cut -d'|' -f3)
    echo "$((i+1)). $UNAME | Expire: $EXP"
  done
  echo "${CYAN}────────────────────────────────────${RESET}"

  read -rp "🔢 Numéro à supprimer (1-${#USERS[@]}): " NUM
  if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#USERS[@]} )); then
    echo "❌ Numéro invalide."
    pause; return
  fi

  local LINE PHONE
  LINE="${USERS[$((NUM-1))]}"
  PHONE=$(echo "$LINE" | cut -d'|' -f1 | tr -d '[:space:]')

  grep -v "^$PHONE|" "$HYSTERIA_USER_FILE" > "${HYSTERIA_USER_FILE}.tmp" || true
  mv "${HYSTERIA_USER_FILE}.tmp" "$HYSTERIA_USER_FILE"
  chmod 600 "$HYSTERIA_USER_FILE"

  update_hysteria_config_passwords
  echo "✅ $PHONE supprimé"
  pause
}

# ---------- 4) Fix ----------
fix_hysteria() {
  print_title
  echo "[4] FIX HYSTERIA (iptables + service)"

  systemctl reset-failed hysteria.service 2>/dev/null || true

  /usr/local/bin/init-nftables.sh

  nft delete table inet hysteria 2>/dev/null || true

  nft -f - << EOF
table inet hysteria {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 20000 accept
        udp dport 20000-50000 accept
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        udp dport 20000-50000 dnat to :20000
    }
}
EOF

  nft list table inet hysteria > /etc/nftables/hysteria.nft
  systemctl reload nftables 2>/dev/null || systemctl restart nftables
  
  systemctl restart hysteria.service || true
  sleep 2

  if systemctl is-active --quiet hysteria.service; then
    echo "✅ Hysteria actif"
  else
    echo "❌ Hysteria toujours inactif - voir: journalctl -u hysteria.service -n 30"
  fi
  pause
}

# ---------- 5) Désinstallation ----------
uninstall_hysteria() {
  print_title
  echo "[5] DÉSINSTALLATION HYSTERIA"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  systemctl stop "$HYSTERIA_SERVICE" 2>/dev/null || true
  systemctl disable "$HYSTERIA_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$HYSTERIA_SERVICE"
  systemctl daemon-reload

  rm -f "$HYSTERIA_BIN"
  rm -rf /etc/hysteria

  nft delete table inet hysteria 2>/dev/null || true
  rm -f /etc/nftables/hysteria.nft
  systemctl reload nftables 2>/dev/null || systemctl restart nftables

  echo "✅ HYSTERIA supprimé"
  pause
}

# ---------- MAIN LOOP ----------
check_root

while true; do
  print_title
  show_status_block
  echo "${GREEN}${BOLD}[01]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Installation de Hysteria${RESET}"
  echo "${GREEN}${BOLD}[02]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Créer un utilisateur HYSTERIA${RESET}"
  echo "${GREEN}${BOLD}[03]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Supprimer utilisateur${RESET}"
  echo "${GREEN}${BOLD}[04]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Fix HYSTERIA (reset firewall/NAT)${RESET}"
  echo "${GREEN}${BOLD}[05]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Désinstaller HYSTERIA${RESET}"
  echo "${RED}[00] ➜ Quitter${RESET}"
  echo
  echo -n "${BOLD}${YELLOW} Entrez votre choix [0-5]: ${RESET}"
  read -r CHOIX

  case $CHOIX in
    1) install_hysteria ;;
    2) create_hysteria_user ;;
    3) delete_hysteria_user ;;
    4) fix_hysteria ;;
    5) uninstall_hysteria ;;
    0) exit 0 ;;
    *) echo "❌ Choix invalide"; sleep 1 ;;
  esac
done
