#!/bin/bash
# sirust.sh - ZIVPN Control Panel
# Optimisé: BBR, buffers UDP larges, fenêtres QUIC, ulimits, QoS

ZIVPN_BIN="/usr/local/bin/zivpn"
ZIVPN_SERVICE="zivpn.service"
ZIVPN_CONFIG="/etc/zivpn/config.json"
ZIVPN_USER_FILE="/etc/zivpn/users.list"
ZIVPN_DOMAIN_FILE="/etc/zivpn/domain.txt"

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

zivpn_installed() {
  [[ -x "$ZIVPN_BIN" ]] && systemctl list-unit-files | grep -q "^$ZIVPN_SERVICE"
}

zivpn_running() {
  systemctl is-active --quiet "$ZIVPN_SERVICE" 2>/dev/null
}

# ==========================================================
# NOUVEAU: Optimisations kernel/réseau complètes pour haut débit
# ==========================================================
apply_network_optimizations() {
    echo "${CYAN}⚙️  Application des optimisations réseau...${RESET}"

    # Charger les modules BBR et FQ (indispensable pour haut débit)
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true

    # Supprimer les anciennes entrées pour éviter les doublons
    local KEYS=(
        "net.core.rmem_default" "net.core.wmem_default"
        "net.core.rmem_max" "net.core.wmem_max"
        "net.core.netdev_max_backlog" "net.core.optmem_max"
        "net.core.default_qdisc" "net.ipv4.tcp_congestion_control"
        "net.ipv4.ip_forward" "net.ipv4.udp_mem"
        "fs.file-max" "net.ipv4.tcp_fastopen"
        "net.ipv4.tcp_mtu_probing"
    )
    for KEY in "${KEYS[@]}"; do
        sed -i "/^${KEY}=/d" /etc/sysctl.conf 2>/dev/null || true
    done

    # Écrire toutes les optimisations
    cat >> /etc/sysctl.conf << 'SYSEOF'

# === ZIVPN High-Speed Optimizations ===
# Buffers UDP larges (67 Mo)
net.core.rmem_default=26214400
net.core.wmem_default=26214400
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.core.optmem_max=25165824
# File descriptor limits
fs.file-max=1000000
# Queue réseau
net.core.netdev_max_backlog=250000
# BBR congestion control (haut débit sur réseau congestionné)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# IP forwarding
net.ipv4.ip_forward=1
# UDP memory pages (min/pressure/max)
net.ipv4.udp_mem=102400 873800 16777216
# TCP Fast Open
net.ipv4.tcp_fastopen=3
# MTU probing
net.ipv4.tcp_mtu_probing=1
# === FIN ZIVPN ===
SYSEOF

    # Appliquer immédiatement
    sysctl -p >/dev/null 2>&1 || true

    # QoS: priorité FQ sur l'interface principale
    local IFACE
    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [[ -n "$IFACE" ]]; then
        tc qdisc del dev "$IFACE" root 2>/dev/null || true
        tc qdisc add dev "$IFACE" root fq 2>/dev/null || true
        echo "${GREEN}✅ FQ qdisc appliqué sur $IFACE${RESET}"
    fi

    echo "${GREEN}✅ Optimisations réseau appliquées (BBR + buffers 67Mo + FQ)${RESET}"
}

# ==========================================================
# NOUVEAU: Générer config.json optimisée (fenêtres QUIC larges)
# ==========================================================
write_optimized_config() {
    cat > "$ZIVPN_CONFIG" << 'EOF'
{
  "listen": ":5667",
  "cert": "/etc/zivpn/zivpn.crt",
  "key": "/etc/zivpn/zivpn.key",
  "obfs": "zivpn",
  "recv_window_conn": 15728640,
  "recv_window_client": 67108864,
  "disable_mtu_discovery": false,
  "max_conn_client": 4096,
  "exclude_port": [53,5300,4466,36712,20000],
  "auth": {
    "mode": "passwords",
    "config": ["zi"]
  }
}
EOF
}

# ==========================================================
# NOUVEAU: Générer le service systemd optimisé
# ==========================================================
write_optimized_service() {
    cat > "/etc/systemd/system/$ZIVPN_SERVICE" << EOF
[Unit]
Description=ZIVPN UDP Server (High-Speed)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$ZIVPN_BIN server -c $ZIVPN_CONFIG
WorkingDirectory=/etc/zivpn
Restart=always
RestartSec=10
StartLimitBurst=0
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
LimitNOFILE=1048576
LimitNPROC=infinity
LimitMEMLOCK=infinity
StandardOutput=append:/var/log/zivpn.log
StandardError=append:/var/log/zivpn.log

[Install]
WantedBy=multi-user.target
EOF
}

# ==========================================================
cleanup_expired_users() {
    [[ ! -f "$ZIVPN_USER_FILE" ]] && return 0
    local TODAY
    TODAY=$(date +%Y-%m-%d)
    local TMP
    TMP=$(mktemp)
    awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP" 2>/dev/null || true
    mv "$TMP" "$ZIVPN_USER_FILE"
    chmod 600 "$ZIVPN_USER_FILE"
    update_zivpn_config_passwords
}

update_zivpn_config_passwords() {
    local TODAY
    TODAY=$(date +%Y-%m-%d)
    local PASSWORDS
    PASSWORDS=$(awk -F'|' -v today="$TODAY" '$3>=today {print $2}' "$ZIVPN_USER_FILE" 2>/dev/null | sort -u | paste -sd, -)

    if [[ -z "$PASSWORDS" ]]; then
        echo "⚠️  Aucun utilisateur actif - config inchangée"
        return 0
    fi

    local TMP
    TMP=$(mktemp)
    if jq --arg passwords "$PASSWORDS" \
          '.auth.config = ($passwords | split(","))' \
          "$ZIVPN_CONFIG" > "$TMP" 2>/dev/null && \
       jq empty "$TMP" >/dev/null 2>&1; then
        mv "$TMP" "$ZIVPN_CONFIG"
        systemctl restart "$ZIVPN_SERVICE" || true
        return 0
    else
        echo "${RED}❌ JSON invalide → config inchangée${RESET}"
        rm -f "$TMP"
        return 1
    fi
}

print_title() {
  clear
  echo "${CYAN}${BOLD}╔═══════════════════════════════════════╗${RESET}"
  echo "${CYAN}║        ZIVPN CONTROL PANEL v2         ║${RESET}"
  echo "${CYAN}║     (Compatible @kighmu 🇨🇲)           ║${RESET}"
  echo "${CYAN}${BOLD}╚═══════════════════════════════════════╝${RESET}"
  echo
}

show_status_block() {
  echo "${CYAN}-------------- STATUT ZIVPN --------------${RESET}"
  local SVC_FILE_OK SVC_ACTIVE PORT_OK ACTIVE_USERS TODAY BBR_STATUS
  SVC_FILE_OK=$([[ -f "/etc/systemd/system/$ZIVPN_SERVICE" ]] && echo "✅" || echo "❌")
  SVC_ACTIVE=$(systemctl is-active "$ZIVPN_SERVICE" 2>/dev/null || echo "inactif")
  PORT_OK=$(ss -lunp 2>/dev/null | grep -q ":5667" && echo "✅" || echo "❌")
  # Vérifier si BBR est actif
  BBR_STATUS=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr" && echo "✅ BBR" || echo "⚠️  non-BBR")
  echo "${WHITE}Service file:${RESET} $SVC_FILE_OK"
  echo "${WHITE}Service actif:${RESET} $SVC_ACTIVE"
  echo "${WHITE}Port 5667:${RESET} $PORT_OK"
  echo "${WHITE}Congestion ctrl:${RESET} $BBR_STATUS"
  if [[ -f "$ZIVPN_USER_FILE" ]]; then
    TODAY=$(date +%Y-%m-%d)
    ACTIVE_USERS=$(awk -F'|' -v today="$TODAY" '$3>=today {count++} END{print count+0}' "$ZIVPN_USER_FILE")
  else
    ACTIVE_USERS=0
  fi
  echo "${CYAN}Utilisateurs actifs:${RESET} $ACTIVE_USERS"
  if [[ "$SVC_FILE_OK" == "✅" ]]; then
    if systemctl is-active --quiet "$ZIVPN_SERVICE" 2>/dev/null; then
      echo "${GREEN}✅ ZIVPN : INSTALLÉ et ACTIF${RESET}"
    else
      echo "⚠️  ZIVPN : INSTALLÉ mais INACTIF"
    fi
  else
    echo "${RED}❌ ZIVPN : NON INSTALLÉ${RESET}"
  fi
  echo "${CYAN}------------------------------------------${RESET}"
  echo
}


# ---------- RESTAURATION utilisateurs ZIVPN depuis la DB panel ----------
restore_zivpn_from_db() {
  local ENV_FILE="/opt/kighmu-panel/.env"
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "⚠️  Panel .env introuvable — restauration DB ignorée."
    return 0
  fi

  # Lire les infos de connexion
  local DB_HOST DB_USER DB_PASS DB_NAME DB_PORT
  DB_HOST=$(grep '^DB_HOST='  "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
  DB_USER=$(grep '^DB_USER='  "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
  DB_PASS=$(grep '^DB_PASSWORD=' "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
  DB_NAME=$(grep '^DB_NAME='  "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
  DB_PORT=$(grep '^DB_PORT='  "$ENV_FILE" | cut -d'=' -f2 | tr -d '"'"'"' ')
  DB_HOST=${DB_HOST:-127.0.0.1}
  DB_PORT=${DB_PORT:-3306}

  # Vérifier que mysql est disponible
  if ! command -v mysql &>/dev/null; then
    echo "⚠️  mysql client introuvable — restauration DB ignorée."
    return 0
  fi

  # Compter les utilisateurs udp-zivpn valides
  local COUNT
  COUNT=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" \
    -N -e "SELECT COUNT(*) FROM clients \
           WHERE tunnel_type='udp-zivpn' \
           AND expires_at >= NOW() \
           AND is_active=1;" \
    "$DB_NAME" 2>/dev/null)

  if [[ -z "$COUNT" || "$COUNT" -eq 0 ]]; then
    echo "⚠️  Aucun utilisateur udp-zivpn actif trouvé en base de données."
    return 0
  fi

  echo "${CYAN}♻️  Restauration de ${COUNT} utilisateur(s) udp-zivpn depuis la DB panel...${RESET}"

  # Récupérer username|password|expires_at depuis la DB
  local ROWS
  ROWS=$(mysql -u"$DB_USER" -p"$DB_PASS" -h"$DB_HOST" -P"$DB_PORT" \
    -N -e "SELECT username, password, DATE(expires_at) FROM clients \
           WHERE tunnel_type='udp-zivpn' \
           AND expires_at >= NOW() \
           AND is_active=1 \
           ORDER BY expires_at ASC;" \
    "$DB_NAME" 2>/dev/null)

  if [[ -z "$ROWS" ]]; then
    echo "❌ Erreur lors de la lecture de la base de données."
    return 1
  fi

  # Construire users.list
  mkdir -p /etc/zivpn
  local TMP
  TMP=$(mktemp)

  # Garder les utilisateurs existants non présents dans la DB (éviter doublons)
  if [[ -f "$ZIVPN_USER_FILE" && -s "$ZIVPN_USER_FILE" ]]; then
    cp "$ZIVPN_USER_FILE" "$TMP"
  fi

  local INJECTED=0
  while IFS=$'\t' read -r UNAME UPASS UEXP; do
    [[ -z "$UNAME" ]] && continue
    # Remplacer si déjà présent, sinon ajouter
    grep -v "^${UNAME}|" "$TMP" > "${TMP}.2" 2>/dev/null || true
    mv "${TMP}.2" "$TMP"
    echo "${UNAME}|${UPASS}|${UEXP}" >> "$TMP"
    (( INJECTED++ ))
  done <<< "$ROWS"

  mv "$TMP" "$ZIVPN_USER_FILE"
  chmod 600 "$ZIVPN_USER_FILE"

  # Synchroniser config.json avec les nouveaux passwords
  update_zivpn_config_passwords

  echo "${GREEN}✅ ${INJECTED} utilisateur(s) udp-zivpn restauré(s) depuis la DB !${RESET}"
}

# ---------- 1) Installation ----------
install_zivpn() {
  print_title
  echo "[1] INSTALLATION ZIVPN"
  echo

  if zivpn_installed; then
    echo "ZIVPN déjà installé."
    pause; return
  fi

  systemctl stop zivpn 2>/dev/null || true
  systemctl stop ufw 2>/dev/null || true
  ufw disable 2>/dev/null || true
  apt purge ufw -y 2>/dev/null || true
  apt update -y && apt install -y wget curl jq openssl iproute2

  wget -q "https://github.com/kinf744/Kighmu/releases/download/v1.0.0/udp-zivpn-linux-amd64" -O "$ZIVPN_BIN"
  chmod +x "$ZIVPN_BIN"

  mkdir -p /etc/zivpn
  read -rp "Domaine: " DOMAIN; DOMAIN=${DOMAIN:-"zivpn.local"}
  echo "$DOMAIN" > "$ZIVPN_DOMAIN_FILE"

  local CERT="/etc/zivpn/zivpn.crt" KEY="/etc/zivpn/zivpn.key"
  openssl req -x509 -newkey rsa:2048 -keyout "$KEY" -out "$CERT" -nodes -days 3650 -subj "/CN=$DOMAIN"
  chmod 600 "$KEY"; chmod 644 "$CERT"

  # Config optimisée (fenêtres QUIC larges)
  write_optimized_config

  # Service systemd optimisé (LimitNPROC + LimitMEMLOCK)
  write_optimized_service

  systemctl daemon-reload && systemctl enable "$ZIVPN_SERVICE"

  # 4️⃣ NFTABLES - table dédiée avec validation avant écriture
/usr/local/bin/init-nftables.sh

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << 'EOF'
table inet zivpn {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 5667 accept
        udp dport 6000-19999 accept
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        udp dport 6000-19999 dnat to :5667
    }
}
EOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/zivpn.nft
    systemctl daemon-reload
    systemctl enable --now nftables-tunnel@zivpn.service
    systemctl restart nftables-tunnel@zivpn.service
    echo "✅ Table nftables zivpn chargée et persistée"
else
    echo "❌ Erreur de syntaxe nftables — table zivpn non appliquée"
    rm -f "$TMP_NFT"
fi

  # Optimisations réseau complètes (BBR + buffers 67Mo + FQ qdisc)
  apply_network_optimizations

  systemctl start "$ZIVPN_SERVICE" || true
  sleep 3

  if systemctl is-active --quiet "$ZIVPN_SERVICE"; then
    local IP
    IP=$(hostname -I | awk '{print $1}')
    echo
    echo "${GREEN}✅ ZIVPN installé et actif !${RESET}"
    echo "📱 Config:"
    echo "   Serveur: $IP"
    echo "   Port: 6000-19999"
    echo "   Password: zi"
    echo "   Obfs: zivpn"
    echo "   recv_window_conn: 15728640 (15 Mo)"
    echo "   recv_window_client: 67108864 (64 Mo)"

    # ── RESTAURATION depuis la DB panel ──
    echo
    echo "${CYAN}?? Restauration des utilisateurs udp-zivpn depuis le panel...${RESET}"
    restore_zivpn_from_db

  else
    echo "❌ ZIVPN ne démarre pas"
    journalctl -u zivpn.service -n 20 --no-pager
  fi
  pause
}

# ---------- 2) Création utilisateur ----------
create_zivpn_user() {
  print_title
  echo "[2] CRÉATION UTILISATEUR ZIVPN"

  if ! systemctl is-active --quiet "$ZIVPN_SERVICE" 2>/dev/null; then
    echo "❌ Service ZIVPN inactif. Lance l'option 1."
    pause; return
  fi

  read -rp "Identifiant (téléphone ou username): " USER_ID
  [[ -z "$USER_ID" ]] && { echo "❌ Identifiant vide"; pause; return; }
  read -rp "Password ZIVPN: " PASS
  [[ -z "$PASS" ]] && { echo "❌ Password vide"; pause; return; }
  read -rp "Durée (jours): " DAYS
  [[ ! "$DAYS" =~ ^[0-9]+$ ]] && { echo "❌ Durée invalide"; pause; return; }

  local EXPIRE TODAY
  EXPIRE=$(date -d "+${DAYS} days" '+%Y-%m-%d')
  TODAY=$(date +%Y-%m-%d)

  local TMP
  TMP=$(mktemp)
  awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP" 2>/dev/null || true
  grep -v "^$USER_ID|" "$TMP" > "${TMP}.2" 2>/dev/null || true
  echo "$USER_ID|$PASS|$EXPIRE" >> "${TMP}.2"
  mv "${TMP}.2" "$ZIVPN_USER_FILE"
  rm -f "$TMP"
  chmod 600 "$ZIVPN_USER_FILE"

  if update_zivpn_config_passwords; then
    local DOMAIN
    DOMAIN=$(cat "$ZIVPN_DOMAIN_FILE" 2>/dev/null || hostname -I | awk '{print $1}')
    echo
    echo "✅ UTILISATEUR CRÉÉ"
    echo "━━━━━━━━━━━━━━━━━━━━━"
    echo "🌐 Domaine  : $DOMAIN"
    echo "🎭 Obfs     : zivpn"
    echo "🔐 Password : $PASS"
    echo "📅 Expire   : $EXPIRE"
    echo "🔌 Port     : 6000-19999"
    echo "━━━━━━━━━━━━━━━━━━━━━"
  fi
  pause
}

# ---------- 3) Suppression utilisateur ----------
delete_zivpn_user() {
  print_title
  echo "[3] SUPPRIMER UTILISATEUR ZIVPN"

  if [[ ! -f "$ZIVPN_USER_FILE" || ! -s "$ZIVPN_USER_FILE" ]]; then
    echo "❌ Aucun utilisateur enregistré."
    pause; return
  fi

  local TODAY
  TODAY=$(date +%Y-%m-%d)
  local TMP
  TMP=$(mktemp)
  awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP" 2>/dev/null || true
  mv "$TMP" "$ZIVPN_USER_FILE"
  chmod 600 "$ZIVPN_USER_FILE"

  mapfile -t USERS < <(sort -t'|' -k3 "$ZIVPN_USER_FILE")
  if [[ ${#USERS[@]} -eq 0 ]]; then
    echo "❌ Aucun utilisateur actif."
    pause; return
  fi

  echo "Utilisateurs actifs:"
  echo "────────────────────────────────────"
  for i in "${!USERS[@]}"; do
    local UNAME EXP
    UNAME=$(echo "${USERS[$i]}" | cut -d'|' -f1)
    EXP=$(echo "${USERS[$i]}" | cut -d'|' -f3)
    echo "$((i+1)). $UNAME | Expire: $EXP"
  done
  echo "────────────────────────────────────"

  read -rp "🔢 Numéro à supprimer (1-${#USERS[@]}): " NUM
  if ! [[ "$NUM" =~ ^[0-9]+$ ]] || (( NUM < 1 || NUM > ${#USERS[@]} )); then
    echo "❌ Numéro invalide."
    pause; return
  fi

  local LINE USER_ID
  LINE="${USERS[$((NUM-1))]}"
  USER_ID=$(echo "$LINE" | cut -d'|' -f1 | tr -d '[:space:]')

  grep -v "^$USER_ID|" "$ZIVPN_USER_FILE" > "${ZIVPN_USER_FILE}.tmp" 2>/dev/null || true
  mv "${ZIVPN_USER_FILE}.tmp" "$ZIVPN_USER_FILE"
  chmod 600 "$ZIVPN_USER_FILE"

  update_zivpn_config_passwords
  echo "✅ $USER_ID supprimé"
  pause
}

# ---------- 4) Fix ----------
fix_zivpn() {
  print_title
  echo "[4] FIX ZIVPN (iptables + service + optimisations)"

  systemctl reset-failed zivpn.service 2>/dev/null || true

  # 4️⃣ NFTABLES - table dédiée avec validation avant écriture
/usr/local/bin/init-nftables.sh

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << 'EOF'
table inet zivpn {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport 5667 accept
        udp dport 6000-19999 accept
    }
    chain prerouting {
        type nat hook prerouting priority -100;
        udp dport 6000-19999 dnat to :5667
    }
}
EOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/zivpn.nft
    systemctl daemon-reload
    systemctl enable --now nftables-tunnel@zivpn.service
    systemctl restart nftables-tunnel@zivpn.service
    echo "✅ Table nftables zivpn chargée et persistée"
else
    echo "❌ Erreur de syntaxe nftables — table zivpn non appliquée"
    rm -f "$TMP_NFT"
fi

  # Réappliquer les optimisations réseau
  apply_network_optimizations

  # Réécrire le service avec les limites correctes
  write_optimized_service
  systemctl daemon-reload

  systemctl restart zivpn.service || true
  sleep 2

  if systemctl is-active --quiet zivpn.service; then
    echo "✅ ZIVPN actif (6000-19999→5667)"
    echo "✅ BBR + buffers + FQ réappliqués"
  else
    echo "❌ ZIVPN toujours inactif - voir: journalctl -u zivpn.service -n 30"
  fi
  pause
}

# ---------- 5) Appliquer optimisations seules (NOUVEAU) ----------
optimize_only() {
  print_title
  echo "[5] APPLIQUER OPTIMISATIONS VITESSE"
  echo
  echo "Cette option applique uniquement les optimisations réseau"
  echo "sans réinstaller ZIVPN (utile si déjà installé)."
  echo

  apply_network_optimizations

  # Mettre à jour la config JSON si elle existe
  if [[ -f "$ZIVPN_CONFIG" ]]; then
    # Vérifier si les champs QUIC sont déjà présents
    if ! jq -e '.recv_window_conn' "$ZIVPN_CONFIG" >/dev/null 2>&1; then
      echo "${CYAN}⚙️  Mise à jour config.json (fenêtres QUIC)...${RESET}"
      local TMP
      TMP=$(mktemp)
      if jq '. + {
        "recv_window_conn": 15728640,
        "recv_window_client": 67108864,
        "disable_mtu_discovery": false,
        "max_conn_client": 4096
      }' "$ZIVPN_CONFIG" > "$TMP" 2>/dev/null && jq empty "$TMP" >/dev/null 2>&1; then
        mv "$TMP" "$ZIVPN_CONFIG"
        echo "${GREEN}✅ config.json mis à jour (fenêtres QUIC 64 Mo)${RESET}"
        systemctl restart "$ZIVPN_SERVICE" || true
      else
        echo "${RED}❌ Erreur mise à jour config.json${RESET}"
        rm -f "$TMP"
      fi
    else
      echo "${GREEN}✅ config.json déjà optimisé${RESET}"
    fi
  fi

  # Mettre à jour le service si LimitNPROC manque
  if [[ -f "/etc/systemd/system/$ZIVPN_SERVICE" ]]; then
    if ! grep -q "LimitNPROC" "/etc/systemd/system/$ZIVPN_SERVICE"; then
      echo "${CYAN}⚙️  Mise à jour service systemd (LimitNPROC/MEMLOCK)...${RESET}"
      write_optimized_service
      systemctl daemon-reload
      systemctl restart "$ZIVPN_SERVICE" || true
      echo "${GREEN}✅ Service systemd mis à jour${RESET}"
    fi
  fi

  echo
  echo "${GREEN}${BOLD}✅ Optimisations complètes appliquées !${RESET}"
  echo "  • BBR congestion control"
  echo "  • Buffers UDP: 67 Mo"
  echo "  • FQ qdisc (priorité paquets)"
  echo "  • recv_window_conn: 15 Mo"
  echo "  • recv_window_client: 64 Mo"
  echo "  • LimitNPROC/MEMLOCK: infinity"
  pause
}

# ---------- 6) Désinstallation ----------
uninstall_zivpn() {
  print_title
  echo "[6] DÉSINSTALLATION ZIVPN"
  read -rp "Confirmer ? (o/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[oO]$ ]] || { echo "Annulé"; pause; return; }

  systemctl stop "$ZIVPN_SERVICE" 2>/dev/null || true
  systemctl disable "$ZIVPN_SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/$ZIVPN_SERVICE"
  systemctl daemon-reload

  rm -f "$ZIVPN_BIN"
  rm -rf /etc/zivpn

  systemctl disable --now nftables-tunnel@zivpn.service 2>/dev/null || true
rm -f /etc/systemd/system/nftables-tunnel@zivpn.service.d/* 2>/dev/null || true
rm -f /etc/nftables/zivpn.nft
systemctl daemon-reload

  echo "✅ ZIVPN supprimé"
  pause
}

# ---------- MAIN LOOP ----------
check_root

while true; do
  print_title
  show_status_block
  echo "${GREEN}${BOLD}[01]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Installation de ZIVPN${RESET}"
  echo "${GREEN}${BOLD}[02]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Créer un utilisateur ZIVPN${RESET}"
  echo "${GREEN}${BOLD}[03]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Supprimer utilisateur${RESET}"
  echo "${GREEN}${BOLD}[04]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Fix ZIVPN (reset firewall/NAT + optimisations)${RESET}"
  echo "${GREEN}${BOLD}[05]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Appliquer optimisations vitesse (BBR/buffers/QUIC)${RESET}"
  echo "${GREEN}${BOLD}[06]${RESET} ${BOLD}${MAGENTA}➜${RESET} ${YELLOW}Désinstaller ZIVPN${RESET}"
  echo "${RED}[00] ➜ Quitter${RESET}"
  echo
  echo -n "${BOLD}${YELLOW} Entrez votre choix [0-6]: ${RESET}"
  read -r CHOIX

  case $CHOIX in
    1) install_zivpn ;;
    2) create_zivpn_user ;;
    3) delete_zivpn_user ;;
    4) fix_zivpn ;;
    5) optimize_only ;;
    6) uninstall_zivpn ;;
    0) exit 0 ;;
    *) echo "${RED}❌ Choix invalide${RESET}"; sleep 1 ;;
  esac
done
