#!/bin/bash
# ================================================================
#   KIGHMU PANEL v2 — Installateur interactif
#   Ubuntu 20.04+ / Debian 11+
#   Compatibilité Xray : Nginx panel sur port 81
# ================================================================

# --- Couleurs ---
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
C='\033[0;36m'; B='\033[1m'; P='\033[0;35m'; NC='\033[0m'

# --- Constantes ---
INSTALL_DIR="/opt/kighmu-panel"
NODE_PORT="3000"          # Port interne Node.js (jamais exposé directement)
NGINX_PORT="8585"         # Port public Nginx HTTP → Xray utilise 81, SSH WS utilise 80
NGINX_PORT_TLS="8587"     # Port HTTPS panel (443 déjà utilisé par Xray)
DB_NAME="kighmu_panel"
DB_USER="kighmu_user"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_SECRET=$(openssl rand -hex 20 2>/dev/null || echo "kighmu-report-$(date +%s)")
TRAFFIC_SCRIPT="/etc/kighmu/traffic-collect.sh"
TRAFFIC_LOG="/var/log/kighmu-traffic.log"
BANDWIDTH_SCRIPT="/usr/local/bin/kighmu-bandwidth.sh"
BANDWIDTH_SERVICE="/etc/systemd/system/kighmu-bandwidth.service"
BANDWIDTH_LOG="/var/log/kighmu-bandwidth.log"

# ================================================================
# MODE AUTO-INSTALL (non-interactif)
# ================================================================
auto_install() {
  export DEBIAN_FRONTEND=noninteractive
  MODE="${AUTO_MODE:-domain}"
  DOMAIN="${AUTO_DOMAIN:-}"
  ADMIN_USER="${AUTO_USER:-admin}"
  ADMIN_PASS="${AUTO_PASS:-$(< /dev/urandom tr -dc 'a-zA-Z0-9@#_-' | head -c 16)}"

  [[ -z "$DOMAIN" ]] && { echo "ERREUR: AUTO_DOMAIN requis"; exit 1; }

  if [[ "$MODE" == "domain" ]]; then
    USE_TLS=1
    ACCESS_URL="https://${DOMAIN}:${NGINX_PORT_TLS}"
  else
    USE_TLS=0
    ACCESS_URL="http://${DOMAIN}:${NGINX_PORT}"
  fi

  do_install
  exit $?
}

# ================================================================
# FONCTIONS UTILITAIRES
# ================================================================
banner() {
  clear
  echo -e "${C}${B}"
  cat << 'EOF'
  ██╗  ██╗██╗ ██████╗ ██╗  ██╗███╗   ███╗██╗   ██╗
  ██║ ██╔╝██║██╔════╝ ██║  ██║████╗ ████║██║   ██║
  █████╔╝ ██║██║  ███╗███████║██╔████╔██║██║   ██║
  ██╔═██╗ ██║██║   ██║██╔══██║██║╚██╔╝██║██║   ██║
  ██║  ██╗██║╚██████╔╝██║  ██║██║ ╚═╝ ██║╚██████╔╝
  ╚═╝  ╚═╝╚═╝ ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝ ╚═════╝
EOF
  echo -e "${NC}"
  echo -e "  ${C}Panel v2${NC} — Gestionnaire de tunnels VPN"
  echo -e "  ${P}Compatible Xray / V2Ray / SSH / UDP${NC}"
  echo -e "  ${Y}Nginx panel : HTTP=${NGINX_PORT} / HTTPS=${NGINX_PORT_TLS} (Xray=81, SSH WS=80 déjà pris)${NC}"
  echo ""
  echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

info()  { echo -e "  ${C}[•]${NC} $1"; }
ok()    { echo -e "  ${G}[✓]${NC} $1"; }
warn()  { echo -e "  ${Y}[!]${NC} $1"; }
err()   { echo -e "  ${R}[✗]${NC} $1"; }
die()   { err "$1"; exit 1; }
sep()   { echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

pause() {
  echo ""
  read -rp "  $(echo -e "${Y}Appuyez sur [Entrée] pour continuer...${NC}")" _
}

confirm() {
  local msg="$1"
  echo ""
  read -rp "  $(echo -e "${Y}${msg} [o/N] : ${NC}")" rep
  [[ "$rep" =~ ^[oOyY]$ ]]
}

# ================================================================
# FONCTION CRÉATION ADMIN (réutilisée à l'install et au reset)
# ================================================================
_create_admin() {
  local uname="$1"
  local upass="$2"
  local idir="${INSTALL_DIR:-/opt/kighmu-panel}"
  local dbname="${DB_NAME:-kighmu_panel}"

  # Écrire le script JS dans le dossier du panel pour avoir accès aux node_modules
  cat > "${idir}/tmp_hash.js" << 'JSEOF'
const b   = require('./node_modules/bcryptjs');
const m   = require('./node_modules/mysql2/promise');
const env = require('./node_modules/dotenv');
env.config({ path: require('path').join(__dirname, '.env') });

async function run() {
  const user = process.env.K_USER;
  const pass = process.env.K_PASS;
  if (!user || !pass) throw new Error('K_USER ou K_PASS manquant');

  const hash = b.hashSync(pass, 12);
  const ok   = b.compareSync(pass, hash);
  if (!ok) throw new Error('Verification bcrypt echouee');

  const db = await m.createConnection({
    host:     process.env.DB_HOST     || '127.0.0.1',
    user:     process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    database: process.env.DB_NAME,
    connectTimeout: 8000,
  });
  await db.execute('DELETE FROM admins');
  await db.execute('INSERT INTO admins (username, password) VALUES (?, ?)', [user, hash]);
  const [rows] = await db.execute('SELECT id, username FROM admins');
  await db.end();
  process.stdout.write('OK:' + rows[0].username);
}
run().catch(e => { process.stderr.write('ERR:' + e.message); process.exit(1); });
JSEOF

  local result
  result=$(cd "${idir}" && K_USER="${uname}" K_PASS="${upass}" node tmp_hash.js 2>&1)
  rm -f "${idir}/tmp_hash.js"

  if echo "${result}" | grep -q "^OK:"; then
    return 0
  else
    echo "  [DEBUG] _create_admin: ${result}" >&2
    return 1
  fi
}

# ================================================================
# MENU PRINCIPAL
# ================================================================
main_menu() {
  while true; do
    banner
    echo -e "  ${B}MENU PRINCIPAL${NC}"
    echo ""
    echo -e "  ${G}[1]${NC}  🚀  Installer Kighmu Panel"
    echo -e "  ${R}[2]${NC}  🗑   Désinstaller / Nettoyer le panel"
    echo -e "  ${C}[3]${NC}  ℹ   Statut du panel installé"
    echo -e "  ${Y}[4]${NC}  🔑  Reinitialiser le mot de passe admin"
    echo -e "  ${C}[5]${NC}  📊  Collecte de trafic (Xray / SSH / V2Ray)"
    echo -e "  ${Y}[0]${NC}  ←   Quitter"
    echo ""
    sep
    echo ""
    read -rp "  $(echo -e "${B}Votre choix : ${NC}")" choice

    case "$choice" in
      1) menu_install ;;
      2) menu_uninstall ;;
      3) menu_status ;;
      4) menu_reset_admin ;;
      5) menu_traffic ;;
      0) echo -e "\n  ${C}Au revoir.${NC}\n"; exit 0 ;;
      *) warn "Option invalide. Réessayez."; sleep 1 ;;
    esac
  done
}

# ================================================================
# MENU INSTALLATION
# ================================================================
menu_install() {
  while true; do
    banner
    echo -e "  ${B}INSTALLATION — Configuration${NC}"
    echo ""
    echo -e "  ${C}[1]${NC}  🌐  Domaine avec TLS (HTTPS — acme.sh)"
    echo -e "  ${C}[2]${NC}  🖥   Adresse IP sans TLS (HTTP)"
    echo -e "  ${Y}[0]${NC}  ←   Retour au menu principal"
    echo ""
    sep
    echo ""
    read -rp "  $(echo -e "${B}Mode d'accès : ${NC}")" mode

    case "$mode" in
      1) collect_config "domain"; break ;;
      2) collect_config "ip";     break ;;
      0) return ;;
      *) warn "Option invalide."; sleep 1 ;;
    esac
  done
}

# ================================================================
# COLLECTE DE LA CONFIGURATION
# ================================================================
collect_config() {
  local mode="$1"

  banner
  echo -e "  ${B}INSTALLATION — Paramètres${NC}"
  echo ""

  # --- Adresse / Domaine ---
  if [[ "$mode" == "domain" ]]; then
    echo -e "  ${C}Mode :${NC} Domaine avec TLS (HTTPS)"
    echo ""
    while true; do
      read -rp "  $(echo -e "${B}Nom de domaine ${Y}(ex: panel.mondomaine.com)${B} : ${NC}")" DOMAIN
      DOMAIN="${DOMAIN,,}"
      [[ -z "$DOMAIN" ]] && { warn "Le domaine ne peut pas être vide."; continue; }
      [[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] && break
      warn "Format de domaine invalide. Réessayez."
    done
    USE_TLS=1
    ACCESS_URL="https://${DOMAIN}:${NGINX_PORT_TLS}"
  else
    echo -e "  ${C}Mode :${NC} Adresse IP sans TLS (HTTP port ${NGINX_PORT})"
    echo ""
    MY_IP=$(curl -s --max-time 4 ifconfig.me 2>/dev/null || curl -s --max-time 4 api.ipify.org 2>/dev/null || echo "")
    if [[ -n "$MY_IP" ]]; then
      echo -e "  ${Y}IP détectée automatiquement : ${B}${MY_IP}${NC}"
      read -rp "  $(echo -e "${B}Adresse IP ${Y}(Entrée pour utiliser ${MY_IP})${B} : ${NC}")" input_ip
      DOMAIN="${input_ip:-$MY_IP}"
    else
      while true; do
        read -rp "  $(echo -e "${B}Adresse IP du VPS : ${NC}")" DOMAIN
        [[ -z "$DOMAIN" ]] && { warn "L'adresse IP ne peut pas être vide."; continue; }
        break
      done
    fi
    USE_TLS=0
    ACCESS_URL="http://${DOMAIN}:${NGINX_PORT}"
  fi

  echo ""
  sep
  echo ""

  # --- Identifiant Admin ---
  echo -e "  ${C}Compte administrateur du panel${NC}"
  echo ""
  while true; do
    read -rp "  $(echo -e "${B}Nom d'utilisateur admin ${Y}(ex: admin)${B} : ${NC}")" ADMIN_USER
    [[ -z "$ADMIN_USER" ]] && { warn "Le nom d'utilisateur ne peut pas être vide."; continue; }
    [[ "${#ADMIN_USER}" -lt 3 ]] && { warn "Minimum 3 caractères."; continue; }
    [[ "$ADMIN_USER" =~ ^[a-zA-Z0-9_-]+$ ]] && break
    warn "Utilisez uniquement des lettres, chiffres, _ ou -"
  done

  echo -e "  ${Y}Caractères autorisés : lettres, chiffres, @  #  _  -  .${NC}"
  echo -e "  ${Y}Evitez les caracteres speciaux comme : point dexclamation dollar guillemets backtick${NC}"
  echo ""
  while true; do
    read -rsp "  $(echo -e "${B}Mot de passe admin ${Y}(min. 8 caractères)${B} : ${NC}")" ADMIN_PASS
    echo ""
    [[ -z "$ADMIN_PASS" ]] && { warn "Le mot de passe ne peut pas être vide."; continue; }
    [[ "${#ADMIN_PASS}" -lt 8 ]] && { warn "Minimum 8 caractères requis."; continue; }
    # Vérifier les caractères interdits qui cassent bash
    if printf "%s" "$ADMIN_PASS" | LC_ALL=C grep -q "[^a-zA-Z0-9@#_. -]"; then
      warn "Caractère interdit détecté. Utilisez uniquement : lettres chiffres @ # _ - ."
      continue
    fi
    read -rsp "  $(echo -e "${B}Confirmez le mot de passe : ${NC}")" ADMIN_PASS2
    echo ""
    [[ "$ADMIN_PASS" == "$ADMIN_PASS2" ]] && break
    warn "Les mots de passe ne correspondent pas. Réessayez."
  done

  echo ""
  sep
  echo ""

  # --- Récapitulatif ---
  echo -e "  ${B}RÉCAPITULATIF${NC}"
  echo ""
  echo -e "  ${C}Mode :${NC}        $([ $USE_TLS -eq 1 ] && echo "HTTPS avec TLS" || echo "HTTP sans TLS")"
  echo -e "  ${C}Adresse :${NC}     ${B}${ACCESS_URL}${NC}"
  echo -e "  ${C}Admin URL :${NC}   ${B}${ACCESS_URL}/admin${NC}"
  echo -e "  ${C}Username :${NC}    ${B}${ADMIN_USER}${NC}"
  echo -e "  ${C}Password :${NC}    ${B}${ADMIN_PASS//?/*}${NC} (masqué)"
  echo -e "  ${C}Port Nginx :${NC}  ${B}$([ $USE_TLS -eq 1 ] && echo "${NGINX_PORT_TLS} (HTTPS)" || echo "${NGINX_PORT} (HTTP)")${NC} (compatible Xray)"
  echo -e "  ${C}Port Node :${NC}   ${B}${NODE_PORT}${NC} (interne uniquement)"
  echo ""

  if ! confirm "Lancer l'installation avec ces paramètres ?"; then
    warn "Installation annulée."
    pause
    return
  fi

  # Lancer l'installation
  do_install
}

# ================================================================
# INSTALLATION PRINCIPALE
# ================================================================
do_install() {
  # Vérifications root + fichiers
  [[ $EUID -ne 0 ]] && die "Exécutez en root : sudo bash install.sh"

  for f in server.js schema.sql admin.html reseller.html; do
    [[ ! -f "$SCRIPT_DIR/$f" ]] && die "Fichier manquant : $f (doit être dans le même dossier que install.sh)"
  done

  # Vérifier si déjà installé
  if [[ -d "$INSTALL_DIR" ]]; then
    warn "Un panel est déjà installé dans $INSTALL_DIR."
    if ! confirm "Écraser l'installation existante ?"; then
      warn "Installation annulée."
      pause
      return
    fi
    info "Suppression de l'ancienne installation..."
    pm2 delete kighmu-panel 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
  fi

  banner
  echo -e "  ${B}INSTALLATION EN COURS...${NC}"
  echo ""
  sep
  echo ""

  # Générer les secrets
  DB_PASS=$(openssl rand -base64 20 | tr -d '=/+' | head -c 24)
  JWT_SECRET=$(openssl rand -base64 64 | tr -d '=/+\n' | head -c 72)

  # ── 1. Mise à jour système ──────────────────────────────────
  STAMP=/var/lib/apt/periodic/update-success-stamp
  if [[ ! -f "$STAMP" ]] || (( $(date +%s) - $(stat -c %Y "$STAMP" 2>/dev/null || echo 0) > 86400 )); then
    info "Mise à jour des paquets système..."
    apt-get update -qq 2>/dev/null
    apt-get upgrade -y -qq 2>/dev/null
    ok "Système à jour"
  else
    ok "Système déjà à jour (mise à jour < 24h) — skip"
  fi

  # ── 2. Node.js 20 ──────────────────────────────────────────
  if ! command -v node &>/dev/null || [[ $(node -v 2>/dev/null | cut -dv -f2 | cut -d. -f1) -lt 18 ]]; then
    info "Installation de Node.js 20..."
    apt-get install -y -qq curl 2>/dev/null
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
    apt-get install -y -qq nodejs 2>/dev/null
  fi
  ok "Node.js $(node -v)"

  # ── 3. MySQL ────────────────────────────────────────────────
  if ! command -v mysql &>/dev/null; then
    info "Installation de MySQL Server..."
    apt-get install -y -qq mysql-server 2>/dev/null
    systemctl start mysql
    systemctl enable mysql
  fi
  ok "MySQL $(mysql --version | awk '{print $3}')"

  # ── 4. Base de données ──────────────────────────────────────
  info "Création de la base de données..."
  mysql -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || die "Erreur MySQL : impossible de créer la base"
  mysql -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" 2>/dev/null
  mysql -e "GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null
  # Import du schéma
  mysql "${DB_NAME}" < "$SCRIPT_DIR/schema.sql" 2>/dev/null || die "Erreur import schema.sql"
  # Hash admin généré après npm install (voir étape 7)
  ADMIN_HASH=""  # sera généré après npm install

  # ── 5. Déploiement des fichiers ─────────────────────────────
  info "Déploiement des fichiers du panel..."
  mkdir -p "$INSTALL_DIR/frontend/admin" "$INSTALL_DIR/frontend/reseller"
  cp "$SCRIPT_DIR/server.js"      "$INSTALL_DIR/server.js"
  cp "$SCRIPT_DIR/admin.html"     "$INSTALL_DIR/frontend/admin/index.html"
  cp "$SCRIPT_DIR/reseller.html"  "$INSTALL_DIR/frontend/reseller/index.html"

  # Page d'accueil
  cat > "$INSTALL_DIR/frontend/index.html" << 'LANDING'
<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Kighmu Panel</title>
<style>*{margin:0;padding:0;box-sizing:border-box}body{background:#030712;color:#e2e8f0;font-family:'Courier New',monospace;min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden}.grid{position:fixed;inset:0;background-image:linear-gradient(rgba(0,200,255,.025) 1px,transparent 1px),linear-gradient(90deg,rgba(0,200,255,.025) 1px,transparent 1px);background-size:50px 50px}.glow{position:fixed;width:600px;height:600px;border-radius:50%;background:radial-gradient(circle,rgba(0,150,255,.08),transparent 70%);top:50%;left:50%;transform:translate(-50%,-50%);animation:pulse 4s ease-in-out infinite}@keyframes pulse{0%,100%{opacity:.5;transform:translate(-50%,-50%) scale(1)}50%{opacity:1;transform:translate(-50%,-50%) scale(1.1)}}.box{position:relative;z-index:1;text-align:center;padding:2rem}.logo{font-size:3rem;font-weight:700;letter-spacing:.3em;background:linear-gradient(135deg,#00c8ff,#7c3aed);-webkit-background-clip:text;-webkit-text-fill-color:transparent;background-clip:text;text-transform:uppercase;margin-bottom:.5rem}.sub{color:#475569;font-size:.72rem;letter-spacing:.4em;text-transform:uppercase;margin-bottom:3rem}.sep{width:200px;height:1px;background:linear-gradient(90deg,transparent,#00c8ff,transparent);margin:0 auto 3rem}.btns{display:flex;gap:1.5rem;justify-content:center;flex-wrap:wrap}.btn{display:inline-block;padding:1rem 2.5rem;text-decoration:none;font-family:'Courier New',monospace;font-size:.85rem;letter-spacing:.2em;text-transform:uppercase;border-radius:4px;transition:all .3s}.ba{background:transparent;border:1px solid #00c8ff;color:#00c8ff}.ba:hover{background:#00c8ff;color:#030712;box-shadow:0 0 30px rgba(0,200,255,.5)}.br{background:transparent;border:1px solid #7c3aed;color:#a78bfa}.br:hover{background:#7c3aed;color:#fff;box-shadow:0 0 30px rgba(124,58,237,.5)}.ver{position:fixed;bottom:1rem;right:1rem;color:#334155;font-size:.7rem}</style>
</head><body><div class="grid"></div><div class="glow"></div>
<div class="box"><div class="logo">KIGHMU</div><div class="sub">Tunnel Management System v2</div><div class="sep"></div>
<div class="btns"><a href="/admin" class="btn ba">⬡ Admin Panel</a><a href="/reseller" class="btn br">⬡ Reseller Panel</a></div></div>
<div class="ver">KIGHMU v2.0</div></body></html>
LANDING
  ok "Fichiers déployés dans $INSTALL_DIR"

  # ── 6. Fichier .env ─────────────────────────────────────────
  info "Génération du fichier de configuration .env..."
  cat > "$INSTALL_DIR/.env" << ENVFILE
# ============================================================
# KIGHMU PANEL v2 — Configuration générée par install.sh
# ============================================================
PORT=${NODE_PORT}
NODE_ENV=production

# Base de données MySQL
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASS}

# Sécurité JWT
JWT_SECRET=${JWT_SECRET}
JWT_EXPIRES_IN=8h
BCRYPT_ROUNDS=12

# Protection brute-force
MAX_LOGIN_ATTEMPTS=5
BLOCK_DURATION_MINUTES=30

# Chemins des configurations tunnel
XRAY_CONFIG=/etc/xray/config.json
V2RAY_CONFIG=/etc/v2ray/config.json
HYSTERIA_USERS=/etc/hysteria/users.json
ZIVPN_USERS=/etc/zivpn/users.list

# Collecte trafic (script traffic-collect.sh)
REPORT_SECRET=${REPORT_SECRET}
ENVFILE
  ok "Fichier .env créé"

  # ── 7. package.json + npm install ──────────────────────────
  info "Création du package.json..."
  cat > "$INSTALL_DIR/package.json" << 'PKG'
{
  "name": "kighmu-panel",
  "version": "2.0.0",
  "description": "Kighmu VPN Tunnel Management Panel",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": {
    "express": "^4.18.2",
    "mysql2": "^3.6.5",
    "bcryptjs": "^2.4.3",
    "jsonwebtoken": "^9.0.2",
    "dotenv": "^16.3.1",
    "helmet": "^7.1.0",
    "cors": "^2.8.5",
    "uuid": "^9.0.0",
    "node-cron": "^3.0.3",
    "systeminformation": "^5.21.20",
    "express-rate-limit": "^7.1.5"
  }
}
PKG

  if [[ ! -d "$INSTALL_DIR/node_modules" ]]; then
    info "Installation des dépendances Node.js..."
    cd "$INSTALL_DIR" && npm install --production --quiet 2>/dev/null
    ok "Dépendances npm installées"
  else
    ok "Dépendances Node.js déjà présentes — skip"
  fi

  # ── Création compte admin ───────────────────────────────────
  info "Création du compte administrateur..."
  _create_admin "${ADMIN_USER}" "${ADMIN_PASS}" && \
    ok "Admin '${ADMIN_USER}' configuré avec votre mot de passe" || \
    { warn "Fallback: mot de passe aleatoire genere"; ADMIN_USER="admin"; ADMIN_PASS="$(< /dev/urandom tr -dc 'a-zA-Z0-9@#_-' | head -c 16)"; _create_admin "$ADMIN_USER" "$ADMIN_PASS"; }

  # ── 8. PM2 ──────────────────────────────────────────────────
  if ! command -v pm2 &>/dev/null; then
    info "Installation de PM2..."
    npm install -g pm2 --quiet 2>/dev/null
  else
    ok "PM2 déjà installé ($(pm2 --version)) — skip"
  fi
  pm2 delete kighmu-panel 2>/dev/null || true
  cd "$INSTALL_DIR"
  pm2 start server.js --name kighmu-panel --time --cwd "$INSTALL_DIR"
  pm2 save --force >/dev/null 2>&1
  # Activer le démarrage automatique
  PM2_STARTUP=$(pm2 startup 2>/dev/null | grep "sudo" | head -1)
  if [[ -n "$PM2_STARTUP" ]]; then
    eval "$PM2_STARTUP" >/dev/null 2>&1 || true
  fi
  ok "Panel démarré avec PM2"

  # ── 9. Nginx ────────────────────────────────────────────────
  info "Installation et configuration Nginx (port ${NGINX_PORT})..."
  if ! command -v nginx &>/dev/null; then
    info "Installation de Nginx..."
    apt-get install -y -qq nginx 2>/dev/null
  else
    ok "Nginx déjà installé ($(nginx -v 2>&1 | cut -d/ -f2)) — skip"
  fi

  # Arrêter Nginx proprement avant de reconfigurer
  systemctl stop nginx 2>/dev/null || true

  # Désactiver le site default qui pourrait entrer en conflit
  rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

  # ── CORRECTION CRITIQUE : certificats SSL manquants ──────────
  # Nginx peut refuser de démarrer si d'autres configs (ex: Xray)
  # référencent des certificats SSL qui n'existent pas encore.
  # On détecte et corrige automatiquement ce cas.
  _fix_missing_ssl_certs() {
    info "Vérification des certificats SSL référencés dans Nginx..."

    # Trouver tous les fichiers ssl_certificate dans /etc/nginx/
    local broken=0
    while IFS= read -r certpath; do
      # Ignorer les lignes commentées
      [[ "$certpath" =~ ^[[:space:]]*# ]] && continue
      # Extraire le chemin du certificat
      local path
      path=$(echo "$certpath" | grep -oP '(?<=ssl_certificate\s)[^;]+' | tr -d ' ')
      [[ -z "$path" ]] && continue

      if [[ ! -f "$path" ]]; then
        warn "Certificat manquant référencé dans Nginx : $path"
        broken=1

        # Chercher le certificat via acme.sh (méthode la plus commune avec Xray)
        local domain
        domain=$(basename "$(dirname "$path")")  # ex: /etc/xray/ → xray
        # Chercher dans acme.sh par nom de domaine ou pattern
        local acme_cert
        acme_cert=$(find /root/.acme.sh/ -name "fullchain.cer" 2>/dev/null | head -1)
        local acme_key
        acme_key=$(find /root/.acme.sh/ -name "*.key" 2>/dev/null | head -1)

        if [[ -n "$acme_cert" && -n "$acme_key" ]]; then
          local cert_dir
          cert_dir=$(dirname "$path")
          mkdir -p "$cert_dir"
          cp "$acme_cert" "$path"
          # Trouver le fichier .key correspondant (ssl_certificate_key)
          local keypath
          keypath=$(grep -r "ssl_certificate_key" /etc/nginx/ 2>/dev/null \
            | grep -v "^#" \
            | grep -oP '(?<=ssl_certificate_key\s)[^;]+' \
            | tr -d ' ' | head -1)
          if [[ -n "$keypath" && ! -f "$keypath" ]]; then
            mkdir -p "$(dirname "$keypath")"
            cp "$acme_key" "$keypath"
            chmod 600 "$keypath"
            ok "Clé privée restaurée → $keypath"
          fi
          ok "Certificat restauré depuis acme.sh → $path"

          # Configurer le renouvellement automatique pour ce domaine
          local acme_domain
          acme_domain=$(basename "$(dirname "$acme_cert")" | sed 's/_ecc$//')
          if [[ -n "$acme_domain" ]]; then
            /root/.acme.sh/acme.sh --install-cert -d "$acme_domain" --ecc \
              --cert-file "$path" \
              --key-file "${keypath:-$cert_dir/xray.key}" \
              --reloadcmd "systemctl reload nginx" \
              >/dev/null 2>&1 && ok "Renouvellement automatique configuré pour $acme_domain" || true
          fi
        else
          # Pas de certificat acme.sh trouvé — commenter le bloc SSL cassé
          warn "Aucun certificat acme.sh trouvé. Désactivation temporaire du bloc SSL cassé..."
          local conffile
          conffile=$(grep -rl "$path" /etc/nginx/ 2>/dev/null | head -1)
          if [[ -n "$conffile" ]]; then
            # Sauvegarder et commenter les lignes ssl_certificate cassées
            cp "$conffile" "${conffile}.bak.$(date +%s)"
            sed -i "s|ssl_certificate[^_]|# ssl_certificate |g" "$conffile"
            sed -i "s|ssl_certificate_key|# ssl_certificate_key|g" "$conffile"
            sed -i "s|listen.*ssl|# listen_ssl_disabled|g" "$conffile"
            warn "Config SSL désactivée temporairement dans : $conffile"
            warn "Sauvegarde : ${conffile}.bak.*"
          fi
        fi
      fi
    done < <(grep -rh "ssl_certificate " /etc/nginx/ 2>/dev/null)

    if [[ $broken -eq 0 ]]; then
      ok "Tous les certificats SSL Nginx sont présents"
    fi
  }

  _fix_missing_ssl_certs

  # ── Écrire la config Kighmu ──────────────────────────────────
  if [[ $USE_TLS -eq 1 ]]; then

    # Chercher les certificats acme.sh existants pour ce domaine
    ACME_DIR="/root/.acme.sh"
    CERT_FILE="" ; KEY_FILE=""

    for acme_subdir in "${ACME_DIR}/${DOMAIN}_ecc" "${ACME_DIR}/${DOMAIN}"; do
      if [[ -f "${acme_subdir}/fullchain.cer" && -f "${acme_subdir}/${DOMAIN}.key" ]]; then
        CERT_FILE="${acme_subdir}/fullchain.cer"
        KEY_FILE="${acme_subdir}/${DOMAIN}.key"
        ok "Certificat acme.sh trouvé : ${acme_subdir}"
        break
      fi
    done

    # Si absent → émettre via acme.sh
    if [[ -z "$CERT_FILE" ]]; then
      info "Émission du certificat TLS via acme.sh pour ${DOMAIN}..."

      if [[ ! -f "${ACME_DIR}/acme.sh" ]]; then
        curl -fsSL https://get.acme.sh | sh -s email=admin@${DOMAIN} >/dev/null 2>&1
        source "${ACME_DIR}/acme.sh.env" 2>/dev/null || true
      fi

      # Config HTTP temporaire pour validation ACME (port 80)
      mkdir -p /var/www/html/.well-known/acme-challenge
      cat > /etc/nginx/sites-available/kighmu << NGINXTEMP
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};
    root /var/www/html;
    location /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://\$host:${NGINX_PORT_TLS}\$request_uri; }
}
NGINXTEMP
      ln -sf /etc/nginx/sites-available/kighmu /etc/nginx/sites-enabled/kighmu
      nginx -t 2>/dev/null && { systemctl start nginx; systemctl enable nginx; }

      iptables -I INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true

      "${ACME_DIR}/acme.sh" --issue -d "${DOMAIN}" --webroot /var/www/html \
        --keylength ec-256 2>/tmp/acme.log

      iptables -D INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || true

      if [[ -f "${ACME_DIR}/${DOMAIN}_ecc/fullchain.cer" ]]; then
        CERT_FILE="${ACME_DIR}/${DOMAIN}_ecc/fullchain.cer"
        KEY_FILE="${ACME_DIR}/${DOMAIN}_ecc/${DOMAIN}.key"
        ok "Certificat TLS émis pour ${DOMAIN}"
      else
        warn "acme.sh échoué (voir /tmp/acme.log) — panel en HTTP sur port ${NGINX_PORT}"
        USE_TLS=0
        ACCESS_URL="http://${DOMAIN}:${NGINX_PORT}"
      fi
    fi

    if [[ $USE_TLS -eq 1 && -n "$CERT_FILE" ]]; then
      cat > /etc/nginx/sites-available/kighmu << NGINXSSL
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name ${DOMAIN};
    return 301 https://\$host:${NGINX_PORT_TLS}\$request_uri;
}

server {
    listen ${NGINX_PORT_TLS} ssl;
    listen [::]:${NGINX_PORT_TLS} ssl;
    server_name ${DOMAIN};
    ssl_certificate     ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    location / {
        proxy_pass         http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
NGINXSSL
      ACCESS_URL="https://${DOMAIN}:${NGINX_PORT_TLS}"
      # Renouvellement automatique acme.sh
      "${ACME_DIR}/acme.sh" --install-cert -d "${DOMAIN}" --ecc \
        --cert-file "${CERT_FILE}" \
        --key-file  "${KEY_FILE}"  \
        --reloadcmd "systemctl reload nginx" \
        >/dev/null 2>&1 || true
      ln -sf /etc/nginx/sites-available/kighmu /etc/nginx/sites-enabled/kighmu
      nginx -t 2>/tmp/nginx_test.log && { systemctl start nginx; systemctl enable nginx; systemctl reload nginx; ok "TLS activé → ${ACCESS_URL}"; } \
        || { err "Nginx config invalide :"; cat /tmp/nginx_test.log; die "Corrigez manuellement."; }
    fi

    if [[ $USE_TLS -eq 0 ]]; then
      cat > /etc/nginx/sites-available/kighmu << NGINXFALLBACK
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name ${DOMAIN} _;
    location / {
        proxy_pass         http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINXFALLBACK
      ln -sf /etc/nginx/sites-available/kighmu /etc/nginx/sites-enabled/kighmu
      nginx -t 2>/dev/null && { systemctl start nginx; systemctl enable nginx; }
    fi

  else
    # Config HTTP simple (accès par IP)
    cat > /etc/nginx/sites-available/kighmu << NGINXHTTP
server {
    listen ${NGINX_PORT};
    listen [::]:${NGINX_PORT};
    server_name ${DOMAIN} _;
    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";
    location / {
        proxy_pass         http://127.0.0.1:${NODE_PORT};
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection 'upgrade';
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;
        proxy_read_timeout 86400;
    }
}
NGINXHTTP
    ln -sf /etc/nginx/sites-available/kighmu /etc/nginx/sites-enabled/kighmu
    ACCESS_URL="http://${DOMAIN}:${NGINX_PORT}"
  fi

  # ── Démarrage final Nginx avec diagnostic clair ──────────────
  if nginx -t 2>/tmp/nginx_test.log; then
    systemctl start nginx 2>/dev/null || true
    systemctl enable nginx 2>/dev/null || true
    sleep 1
    if systemctl is-active nginx >/dev/null 2>&1; then
      ok "Nginx actif sur le port ${NGINX_PORT}"
    else
      err "Nginx a démarré puis s'est arrêté immédiatement."
      warn "Consultez les logs : journalctl -u nginx -n 20 --no-pager"
    fi
  else
    err "La configuration Nginx contient encore des erreurs :"
    cat /tmp/nginx_test.log
    echo ""
    warn "Le panel Node.js fonctionne sur http://127.0.0.1:${NODE_PORT}"
    warn "Corrigez Nginx manuellement puis : systemctl start nginx"
    warn "Fichiers de config Nginx : /etc/nginx/conf.d/ et /etc/nginx/sites-enabled/"
  fi

  # ── 10. Firewall ────────────────────────────────────────────
  if command -v ufw &>/dev/null; then
    if [[ $USE_TLS -eq 1 ]]; then
      ufw allow ${NGINX_PORT_TLS}/tcp >/dev/null 2>&1 || true
      ufw allow ${NGINX_PORT}/tcp     >/dev/null 2>&1 || true
      ufw deny  ${NODE_PORT}/tcp      >/dev/null 2>&1 || true
      ok "Firewall : ports ${NGINX_PORT_TLS}(HTTPS) et ${NGINX_PORT}(redirect) ouverts"
    else
      ufw allow ${NGINX_PORT}/tcp >/dev/null 2>&1 || true
      ufw deny  ${NODE_PORT}/tcp  >/dev/null 2>&1 || true
      ok "Firewall : port ${NGINX_PORT} ouvert, ${NODE_PORT} bloqué (interne uniquement)"
    fi
  else
    if [[ $USE_TLS -eq 1 ]]; then
      iptables -I INPUT -p tcp --dport ${NGINX_PORT_TLS} -j ACCEPT 2>/dev/null || true
      iptables -I INPUT -p tcp --dport ${NGINX_PORT}     -j ACCEPT 2>/dev/null || true
      ok "Firewall iptables : ports ${NGINX_PORT_TLS}(HTTPS) et ${NGINX_PORT}(redirect) ouverts"
    else
      iptables -I INPUT -p tcp --dport ${NGINX_PORT} -j ACCEPT 2>/dev/null || true
      ok "Firewall iptables : port ${NGINX_PORT} ouvert"
    fi
  fi



  # ── Déploiement du service bandwidth (boucle 5s temps réel) ─
  info "Déploiement du service bandwidth SSH..."
  setup_bandwidth_service "silent"
  ok "Service kighmu-bandwidth déployé (boucle 5s)"

  # ── Déploiement du script de collecte de trafic (Xray/V2Ray) ─
  info "Déploiement du script de collecte de trafic..."
  setup_traffic_cron "silent"
  ok "Collecte trafic configurée (cron toutes les 2 min)"

  # ── Sauvegarde des infos ─────────────────────────────────────
  cat > "$INSTALL_DIR/.install_info" << INFOFILE
DOMAIN=${DOMAIN}
ADMIN_USER=${ADMIN_USER}
USE_TLS=${USE_TLS}
ACCESS_URL=${ACCESS_URL}
NGINX_PORT=${NGINX_PORT}
NODE_PORT=${NODE_PORT}
INSTALL_DATE=$(date '+%Y-%m-%d %H:%M:%S')
INFOFILE

  # ── Synchroniser le domaine pour menu1.sh et le panel ────────
  mkdir -p /etc/kighmu
  echo "${DOMAIN}" > /etc/kighmu/domain.txt
  chmod 644 /etc/kighmu/domain.txt

  # Mettre à jour ou créer ~/.kighmu_info (utilisé par menu1.sh)
  if [ -f "$HOME/.kighmu_info" ]; then
    # Mettre à jour DOMAIN si la ligne existe déjà
    if grep -q "^DOMAIN=" "$HOME/.kighmu_info"; then
      sed -i "s|^DOMAIN=.*|DOMAIN=${DOMAIN}|" "$HOME/.kighmu_info"
    else
      echo "DOMAIN=${DOMAIN}" >> "$HOME/.kighmu_info"
    fi
  else
    # Créer le fichier minimal
    cat > "$HOME/.kighmu_info" << KIGHMUINFO
DOMAIN=${DOMAIN}
ACCESS_URL=${ACCESS_URL}
KIGHMUINFO
  fi
  ok "Domaine '${DOMAIN}' synchronisé → /etc/kighmu/domain.txt + ~/.kighmu_info"

  # ── Test final ───────────────────────────────────────────────
  echo ""
  info "Vérification finale..."
  sleep 2
  NODE_OK=0; NGINX_OK=0
  curl -sf --max-time 5 "http://127.0.0.1:${NODE_PORT}/health" | grep -q '"panel"' && NODE_OK=1
  curl -sf --max-time 5 "http://127.0.0.1:${NGINX_PORT}/"      | grep -qi "kighmu\|html" && NGINX_OK=1
  [[ $NODE_OK  -eq 1 ]] && ok "Node.js opérationnel (port ${NODE_PORT})" || warn "Node.js ne répond pas → pm2 logs kighmu-panel"
  [[ $NGINX_OK -eq 1 ]] && ok "Nginx proxy opérationnel (port ${NGINX_PORT})" || warn "Nginx ne répond pas → nginx -t && systemctl status nginx"

  # ── Résumé ───────────────────────────────────────────────────
  echo ""
  sep
  echo ""
  echo -e "  ${G}${B}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "  ${G}${B}║      KIGHMU PANEL v2 — INSTALLATION RÉUSSIE !    ║${NC}"
  echo -e "  ${G}${B}╚══════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  ${C}🌐 Accès :${NC}"
  echo -e "     ${B}${ACCESS_URL}${NC}"
  echo -e "     ${B}${ACCESS_URL}/admin${NC}     ← Admin"
  echo -e "     ${B}${ACCESS_URL}/reseller${NC}  ← Revendeur"
  echo ""
  echo -e "  ${C}🔑 Identifiants admin :${NC}"
  echo -e "     Username : ${B}${ADMIN_USER}${NC}"
  echo -e "     Password : ${B}${ADMIN_PASS}${NC}"
  echo ""
  echo -e "  ${C}🔧 Architecture :${NC}  Internet → Nginx:${B}$([ $USE_TLS -eq 1 ] && echo "${NGINX_PORT_TLS}(HTTPS)" || echo "${NGINX_PORT}(HTTP)")${NC} → Node:${B}${NODE_PORT}${NC} (interne)"
  echo -e "  ${C}📋 Commandes :${NC}"
  echo -e "     ${Y}pm2 logs kighmu-panel${NC}    — Logs Node.js"
  echo -e "     ${Y}pm2 restart kighmu-panel${NC} — Redémarrer Node.js"
  echo -e "     ${Y}systemctl restart nginx${NC}  — Redémarrer Nginx"
  echo -e "     ${Y}nginx -t${NC}                 — Tester config Nginx"
  echo ""
  sep

  pause
}
# ================================================================
# MENU DÉSINSTALLATION
# ================================================================
menu_uninstall() {
  while true; do
    banner
    echo -e "  ${R}${B}DÉSINSTALLATION / NETTOYAGE${NC}"
    echo ""

    # Afficher ce qui est installé
    if [[ -d "$INSTALL_DIR" ]]; then
      echo -e "  ${G}Panel installé détecté :${NC} $INSTALL_DIR"
      if [[ -f "$INSTALL_DIR/.install_info" ]]; then
        source "$INSTALL_DIR/.install_info" 2>/dev/null
        echo -e "  ${C}Domaine/IP :${NC} ${DOMAIN:-inconnu}"
        echo -e "  ${C}Admin :${NC}      ${ADMIN_USER:-inconnu}"
        echo -e "  ${C}Installé le :${NC} ${INSTALL_DATE:-inconnu}"
      fi
    else
      echo -e "  ${Y}Aucun panel installé détecté dans $INSTALL_DIR${NC}"
    fi

    echo ""
    echo -e "  ${R}[1]${NC}  💣  Désinstallation complète (panel + DB + Nginx)"
    echo -e "  ${Y}[2]${NC}  🔄  Désinstaller uniquement le panel (garder DB)"
    echo -e "  ${Y}[3]${NC}  🗄   Supprimer uniquement la base de données"
    echo -e "  ${C}[0]${NC}  ←   Retour au menu principal"
    echo ""
    sep
    echo ""
    read -rp "  $(echo -e "${B}Votre choix : ${NC}")" choice

    case "$choice" in
      1) uninstall_full ;;
      2) uninstall_panel_only ;;
      3) uninstall_db_only ;;
      0) return ;;
      *) warn "Option invalide."; sleep 1 ;;
    esac
  done
}

uninstall_full() {
  banner
  echo -e "  ${R}${B}DÉSINSTALLATION COMPLÈTE${NC}"
  echo ""
  echo -e "  ${Y}Cette action va supprimer :${NC}"
  echo -e "   • Le panel dans $INSTALL_DIR"
  echo -e "   • La base de données MySQL '${DB_NAME}'"
  echo -e "   • L'utilisateur MySQL '${DB_USER}'"
  echo -e "   • La configuration Nginx kighmu"
  echo -e "   • Le processus PM2 kighmu-panel"
  echo ""

  if ! confirm "Confirmer la désinstallation COMPLÈTE ? Cette action est irréversible."; then
    warn "Désinstallation annulée."
    pause
    return
  fi

  _stop_pm2
  _remove_nginx
  _remove_database
  _remove_files

  echo ""
  ok "Désinstallation complète terminée."
  echo -e "  ${C}Le panel Kighmu a été entièrement supprimé.${NC}"
  pause
}

uninstall_panel_only() {
  banner
  echo -e "  ${Y}${B}DÉSINSTALLATION DU PANEL (base de données conservée)${NC}"
  echo ""

  if ! confirm "Supprimer le panel (fichiers + PM2 + Nginx) mais garder la base de données ?"; then
    warn "Annulé."
    pause
    return
  fi

  _stop_pm2
  _remove_nginx
  _remove_files

  echo ""
  ok "Panel supprimé. Base de données conservée."
  pause
}

uninstall_db_only() {
  banner
  echo -e "  ${Y}${B}SUPPRESSION DE LA BASE DE DONNÉES${NC}"
  echo ""

  if ! confirm "Supprimer la base de données '${DB_NAME}' et l'utilisateur '${DB_USER}' ?"; then
    warn "Annulé."
    pause
    return
  fi

  _remove_database
  echo ""
  ok "Base de données supprimée."
  pause
}

_stop_pm2() {
  info "Arrêt du panel (PM2)..."
  if command -v pm2 &>/dev/null; then
    pm2 stop kighmu-panel 2>/dev/null || true
    pm2 delete kighmu-panel 2>/dev/null || true
    pm2 save --force >/dev/null 2>&1 || true
    ok "Processus PM2 arrêté et supprimé"
  else
    warn "PM2 non trouvé — rien à arrêter"
  fi
}

_remove_nginx() {
  info "Suppression de la configuration Nginx..."
  rm -f /etc/nginx/sites-enabled/kighmu 2>/dev/null || true
  rm -f /etc/nginx/sites-available/kighmu 2>/dev/null || true
  if command -v nginx &>/dev/null && nginx -t 2>/dev/null; then
    systemctl reload nginx 2>/dev/null || true
    ok "Configuration Nginx supprimée"
  fi
  # Retirer la règle firewall
  ufw delete allow ${NGINX_PORT}/tcp >/dev/null 2>&1 || true
}

_remove_database() {
  info "Suppression de la base de données MySQL..."
  if command -v mysql &>/dev/null; then
    mysql -e "DROP DATABASE IF EXISTS ${DB_NAME};" 2>/dev/null && ok "Base de données '${DB_NAME}' supprimée" || warn "Impossible de supprimer la base de données"
    mysql -e "DROP USER IF EXISTS '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" 2>/dev/null && ok "Utilisateur MySQL '${DB_USER}' supprimé" || warn "Impossible de supprimer l'utilisateur MySQL"
  else
    warn "MySQL non trouvé"
  fi
}

_remove_files() {
  info "Suppression des fichiers du panel..."
  if [[ -d "$INSTALL_DIR" ]]; then
    rm -rf "$INSTALL_DIR"
    ok "Dossier $INSTALL_DIR supprimé"
  else
    warn "Dossier $INSTALL_DIR introuvable"
  fi
}

# ================================================================
# STATUT DU PANEL
# ================================================================
menu_status() {
  banner
  echo -e "  ${B}STATUT DU PANEL${NC}"
  echo ""

  # Fichiers
  if [[ -d "$INSTALL_DIR" ]]; then
    echo -e "  ${G}[✓]${NC} Fichiers installés dans : ${C}$INSTALL_DIR${NC}"
    if [[ -f "$INSTALL_DIR/.install_info" ]]; then
      source "$INSTALL_DIR/.install_info" 2>/dev/null
      echo -e "  ${G}[✓]${NC} Domaine / IP : ${C}${DOMAIN:-?}${NC}"
      echo -e "  ${G}[✓]${NC} Admin        : ${C}${ADMIN_USER:-?}${NC}"
      echo -e "  ${G}[✓]${NC} URL d'accès  : ${C}${ACCESS_URL:-?}${NC}"
      echo -e "  ${G}[✓]${NC} Date install : ${C}${INSTALL_DATE:-?}${NC}"
    fi
  else
    echo -e "  ${R}[✗]${NC} Panel non installé ($INSTALL_DIR introuvable)"
  fi

  echo ""

  # PM2
  if command -v pm2 &>/dev/null; then
    PM2_STATUS=$(pm2 list 2>/dev/null | grep kighmu-panel | awk '{print $12}' || echo "")
    if [[ "$PM2_STATUS" == "online" ]]; then
      echo -e "  ${G}[✓]${NC} PM2 : ${G}online${NC}"
    elif [[ -n "$PM2_STATUS" ]]; then
      echo -e "  ${Y}[!]${NC} PM2 : ${Y}${PM2_STATUS}${NC}"
    else
      echo -e "  ${R}[✗]${NC} PM2 : non démarré"
    fi
  else
    echo -e "  ${R}[✗]${NC} PM2 non installé"
  fi

  # Nginx
  if command -v nginx &>/dev/null; then
    if nginx -t 2>/dev/null; then
      echo -e "  ${G}[✓]${NC} Nginx : opérationnel (port ${NGINX_PORT})"
    else
      echo -e "  ${Y}[!]${NC} Nginx : erreur de configuration"
    fi
  else
    echo -e "  ${R}[✗]${NC} Nginx non installé"
  fi

  # MySQL
  if command -v mysql &>/dev/null; then
    if mysql -e "USE ${DB_NAME};" 2>/dev/null; then
      echo -e "  ${G}[✓]${NC} MySQL : base de données '${DB_NAME}' accessible"
    else
      echo -e "  ${Y}[!]${NC} MySQL : base de données '${DB_NAME}' inaccessible"
    fi
  else
    echo -e "  ${R}[✗]${NC} MySQL non installé"
  fi

  # Port en écoute
  echo ""
  if command -v ss &>/dev/null; then
    if ss -tlnp 2>/dev/null | grep -q ":${NODE_PORT} "; then
      echo -e "  ${G}[✓]${NC} Port Node.js ${NODE_PORT} : en écoute"
    else
      echo -e "  ${R}[✗]${NC} Port Node.js ${NODE_PORT} : non actif"
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${NGINX_PORT} "; then
      echo -e "  ${G}[✓]${NC} Port Nginx ${NGINX_PORT} : en écoute"
    else
      echo -e "  ${R}[✗]${NC} Port Nginx ${NGINX_PORT} : non actif"
    fi
  fi

  echo ""
  sep
  pause
}

# ================================================================
# RESET MOT DE PASSE ADMIN
# ================================================================
menu_reset_admin() {
  banner
  echo -e "  ${Y}${B}RÉINITIALISATION MOT DE PASSE ADMIN${NC}"
  echo ""

  if [[ ! -d "$INSTALL_DIR" ]]; then
    err "Panel non installé ($INSTALL_DIR introuvable)."
    pause; return
  fi

  # Saisie nouveau username
  while true; do
    read -rp "  $(echo -e "${B}Nouveau username admin : ${NC}")" NEW_USER
    [[ -z "$NEW_USER" ]] && { warn "Ne peut pas être vide."; continue; }
    [[ "${#NEW_USER}" -lt 3 ]] && { warn "Minimum 3 caractères."; continue; }
    [[ "$NEW_USER" =~ ^[a-zA-Z0-9_-]+$ ]] && break
    warn "Lettres, chiffres, _ ou - uniquement."
  done

  # Saisie nouveau mot de passe
  echo -e "  ${Y}Caractères autorisés : lettres chiffres @ # _ - .${NC}"
  while true; do
    read -rsp "  $(echo -e "${B}Nouveau mot de passe (min. 8 car.) : ${NC}")" NEW_PASS
    echo ""
    [[ -z "$NEW_PASS" ]] && { warn "Ne peut pas être vide."; continue; }
    [[ "${#NEW_PASS}" -lt 8 ]] && { warn "Minimum 8 caractères."; continue; }
    if printf "%s" "$NEW_PASS" | LC_ALL=C grep -q "[^a-zA-Z0-9@#_. -]"; then
      warn "Caractère interdit. Utilisez : lettres chiffres @ # _ - ."
      continue
    fi
    read -rsp "  $(echo -e "${B}Confirmez le mot de passe : ${NC}")" NEW_PASS2
    echo ""
    [[ "$NEW_PASS" == "$NEW_PASS2" ]] && break
    warn "Les mots de passe ne correspondent pas."
  done

  echo ""
  info "Mise à jour du compte admin..."

  if _create_admin "${NEW_USER}" "${NEW_PASS}"; then
    echo ""
    ok "Compte admin réinitialisé avec succès !"
    echo ""
    echo -e "  ${C}Username :${NC} ${B}${NEW_USER}${NC}"
    echo -e "  ${C}Password :${NC} ${B}${NEW_PASS}${NC}"
    echo ""
    # Redémarrer PM2 pour vider le cache JWT
    pm2 restart kighmu-panel >/dev/null 2>&1 && ok "Panel redémarré (cache JWT vidé)" || true
  else
    err "Echec de la réinitialisation. Vérifiez :"
    warn "  • MySQL actif :  systemctl status mysql"
    warn "  • .env correct : cat /opt/kighmu-panel/.env"
  fi

  pause
}


# ================================================================
# SERVICE BANDWIDTH SSH — boucle temps réel /proc/pid/io
# Même mécanisme exact que FirewallFalcon/menu.sh
# ================================================================
setup_bandwidth_service() {
  local silent="${1:-}"

  # Lire le secret depuis .env ou traffic-collect.sh
  local secret="${REPORT_SECRET:-}"
  if [[ -z "$secret" && -f "$INSTALL_DIR/.env" ]]; then
    secret=$(grep '^REPORT_SECRET=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d'=' -f2)
  fi
  [[ -z "$secret" ]] && secret="kighmu-report-$(date +%s)"

  local panel_url="http://127.0.0.1:${NODE_PORT}"

  mkdir -p /var/lib/kighmu/bandwidth/pidtrack
  mkdir -p /var/lib/kighmu/bandwidth/sent

  # ── Écrire le script kighmu-bandwidth.sh ───────────────────
  cat > "$BANDWIDTH_SCRIPT" << BWEOF
#!/bin/bash
# ================================================================
# kighmu-bandwidth.sh — Comptage trafic SSH temps réel
# Mécanisme identique à FirewallFalcon/menu.sh
# Boucle toutes les 5 secondes via service systemd
# ================================================================
USER_FILE="/etc/kighmu/users.list"
BW_DIR="/var/lib/kighmu/bandwidth"
PID_DIR="\$BW_DIR/pidtrack"
SENT_DIR="\$BW_DIR/sent"
PANEL_URL="${panel_url}"
SECRET="${secret}"

mkdir -p "\$BW_DIR" "\$PID_DIR" "\$SENT_DIR"

# Envoi au panel toutes les 2 minutes = 24 cycles de 5s
SEND_EVERY=24
cycle=0

declare -A pending_up
declare -A pending_down

send_to_panel() {
    local has_data=0
    local json='{"stats":['
    local first=1
    for uname in "\${!pending_up[@]}"; do
        local up="\${pending_up[\$uname]:-0}"
        local dn="\${pending_down[\$uname]:-0}"
        (( up + dn == 0 )) && continue
        [ \$first -eq 0 ] && json+=","
        json+="{"username":"\${uname}","upload_bytes":\${up},"download_bytes":\${dn}}"
        first=0
        has_data=1
    done
    json+="]}"
    [ \$has_data -eq 0 ] && return
    curl -s --max-time 10 -X POST "\${PANEL_URL}/api/report/traffic" \
        -H "Content-Type: application/json" \
        -H "x-report-secret: \${SECRET}" \
        -d "\${json}" > /dev/null 2>&1 || true
    # Réinitialiser
    for uname in "\${!pending_up[@]}"; do
        pending_up["\$uname"]=0
        pending_down["\$uname"]=0
    done
}

echo "[\$(date '+%Y-%m-%d %H:%M:%S')] kighmu-bandwidth service démarré"

# ── BOUCLE PRINCIPALE — toutes les 5 secondes ──────────────
while true; do
    [[ ! -f "\$USER_FILE" ]] && { sleep 5; continue; }

    while IFS='|' read -r username _rest; do
        [[ -z "\$username" ]] && continue

        user_uid=\$(id -u "\$username" 2>/dev/null) || continue

        # Méthode 1 : pgrep
        pids=\$(pgrep -u "\$username" sshd 2>/dev/null | tr '
' ' ')

        # Méthode 2 : scan /proc/*/loginuid (sessions WS/SSL/SlowDNS tunnelées)
        for p in /proc/[0-9]*/loginuid; do
            [[ ! -f "\$p" ]] && continue
            luid=\$(cat "\$p" 2>/dev/null)
            [[ -z "\$luid" || "\$luid" == "4294967295" ]] && continue
            [[ "\$luid" != "\$user_uid" ]] && continue
            pid_dir=\$(dirname "\$p")
            pid_num=\$(basename "\$pid_dir")
            cname=\$(cat "\$pid_dir/comm" 2>/dev/null)
            [[ "\$cname" != "sshd" ]] && continue
            ppid_val=\$(awk '/^PPid:/{print \$2}' "\$pid_dir/status" 2>/dev/null)
            [[ "\$ppid_val" == "1" ]] && continue
            pids="\$pids \$pid_num"
        done

        pids=\$(echo "\$pids" | tr ' ' '
' | sort -u | grep -v '^\$' | tr '
' ' ')

        usagefile="\$BW_DIR/\${username}.usage"
        accumulated=0
        if [[ -f "\$usagefile" ]]; then
            accumulated=\$(cat "\$usagefile" 2>/dev/null)
            [[ ! "\$accumulated" =~ ^[0-9]+\$ ]] && accumulated=0
        fi

        if [[ -z "\$pids" ]]; then
            rm -f "\$PID_DIR/\${username}__"*.last 2>/dev/null
            continue
        fi

        delta_total=0
        for pid in \$pids; do
            [[ -z "\$pid" ]] && continue
            io_file="/proc/\$pid/io"
            cur=0
            if [[ -r "\$io_file" ]]; then
                rchar=\$(awk '/^rchar:/{print \$2}' "\$io_file" 2>/dev/null); rchar=\${rchar:-0}
                wchar=\$(awk '/^wchar:/{print \$2}' "\$io_file" 2>/dev/null); wchar=\${wchar:-0}
                cur=\$(( rchar + wchar ))
            fi
            pidfile="\$PID_DIR/\${username}__\${pid}.last"
            if [[ -f "\$pidfile" ]]; then
                prev=\$(cat "\$pidfile" 2>/dev/null)
                [[ ! "\$prev" =~ ^[0-9]+\$ ]] && prev=0
                if [[ "\$cur" -ge "\$prev" ]]; then
                    delta_total=\$(( delta_total + cur - prev ))
                else
                    delta_total=\$(( delta_total + cur ))
                fi
            fi
            echo "\$cur" > "\$pidfile"
        done

        # Nettoyer PIDs morts
        for f in "\$PID_DIR/\${username}__"*.last; do
            [[ ! -f "\$f" ]] && continue
            fpid=\$(basename "\$f" .last)
            fpid=\${fpid#\${username}__}
            [[ ! -d "/proc/\$fpid" ]] && rm -f "\$f"
        done

        # Mettre à jour cumul
        new_total=\$(( accumulated + delta_total ))
        echo "\$new_total" > "\$usagefile"

        # Accumuler delta pour envoi
        if (( delta_total > 0 )); then
            half=\$(( delta_total / 2 ))
            other=\$(( delta_total - half ))
            pending_up["\$username"]=\$(( \${pending_up[\$username]:-0} + half ))
            pending_down["\$username"]=\$(( \${pending_down[\$username]:-0} + other ))
        fi

    done < "\$USER_FILE"

    # ── Envoyer au panel toutes les 2 minutes ───────────────────
    # NOTE: Le trafic UDP Zivpn/Hysteria est mesuré par Auto-clean.sh
    # via iptables global (chaîne KIGHMU_UDP_COUNT) — pas dans cette boucle
    (( cycle++ ))
    if (( cycle >= SEND_EVERY )); then
        send_to_panel
        cycle=0
    fi

    sleep 5

done
BWEOF

  chmod +x "$BANDWIDTH_SCRIPT"

  # ── Écrire le service systemd ───────────────────────────────
  cat > "$BANDWIDTH_SERVICE" << SVCEOF
[Unit]
Description=KIGHMU SSH Bandwidth Monitor
Documentation=Comptage trafic SSH temps reel via /proc/pid/io
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart=$BANDWIDTH_SCRIPT
Restart=always
RestartSec=5
StandardOutput=append:$BANDWIDTH_LOG
StandardError=append:$BANDWIDTH_LOG

[Install]
WantedBy=multi-user.target
SVCEOF

  # ── Activer et démarrer le service ─────────────────────────
  systemctl daemon-reload
  systemctl enable kighmu-bandwidth 2>/dev/null || true
  systemctl restart kighmu-bandwidth 2>/dev/null || true
  touch "$BANDWIDTH_LOG"
  chmod 640 "$BANDWIDTH_LOG"

  if [[ "$silent" != "silent" ]]; then
    ok "Service bandwidth déployé : $BANDWIDTH_SCRIPT"
    ok "Service systemd actif : kighmu-bandwidth (boucle 5s)"
    ok "Logs : $BANDWIDTH_LOG"
  fi
}

# ================================================================
# COLLECTE DE TRAFIC VPN — Script + Cron
# ================================================================
setup_traffic_cron() {
  local silent="${1:-}"

  # Lire le REPORT_SECRET depuis le .env si installé
  local secret="${REPORT_SECRET:-}"
  if [[ -z "$secret" && -f "$INSTALL_DIR/.env" ]]; then
    secret=$(grep '^REPORT_SECRET=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d'=' -f2)
  fi
  [[ -z "$secret" ]] && secret="kighmu-report-$(date +%s)"

  local panel_url="http://127.0.0.1:${NODE_PORT}"

  # Créer le répertoire kighmu
  mkdir -p /etc/kighmu
  mkdir -p /var/lib/kighmu/ssh-counters

  # ── Écrire le script traffic-collect.sh ──────────────────
  cat > "$TRAFFIC_SCRIPT" << TRAFFIC_EOF
#!/bin/bash
# =============================================================
# KIGHMU PANEL v2 — Collecte des statistiques de trafic VPN
# Généré par install.sh
# =============================================================
PANEL_URL="${panel_url}"
SECRET="${secret}"
XRAY_BIN="\${XRAY_BIN:-/usr/local/bin/xray}"
XRAY_API="\${XRAY_API:-127.0.0.1:10085}"
V2RAY_BIN="\${V2RAY_BIN:-/usr/local/bin/v2ray}"
V2RAY_API="\${V2RAY_API:-127.0.0.1:10086}"
DELTA_DIR="/var/lib/kighmu/ssh-counters"
USER_FILE="/etc/kighmu/users.list"
TS="\$(date '+%Y-%m-%d %H:%M:%S')"

mkdir -p "\$DELTA_DIR"

send_stats() {
  local resp
  resp=\$(curl -s --max-time 10 -X POST "\${PANEL_URL}/api/report/traffic" \\
    -H "Content-Type: application/json" \\
    -H "x-report-secret: \${SECRET}" \\
    -d "\$1" 2>/dev/null)
  echo "[\${TS}] → \${resp:-no response}"
}

# ── XRAY : API gRPC statsquery ──────────────────────────────
collect_xray() {
  [ ! -x "\$XRAY_BIN" ] && return
  local raw
  raw=\$("\$XRAY_BIN" api statsquery --server="\$XRAY_API" 2>/dev/null) || return
  [ -z "\$raw" ] && { echo "[\${TS}] [XRAY] Aucune stat"; return; }
  local json='{"stats":[' first=1
  declare -A up_map down_map
  while IFS= read -r line; do
    if [[ "\$line" =~ name:\"user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link\" ]]; then
      local user="\${BASH_REMATCH[1]}" dir="\${BASH_REMATCH[2]}" val=0
      [[ "\$line" =~ value:\"([0-9]+)\" ]] && val="\${BASH_REMATCH[1]}"
      [[ "\$dir" == "up"   ]] && up_map["\$user"]=\$(( \${up_map["\$user"]:-0} + val ))
      [[ "\$dir" == "down" ]] && down_map["\$user"]=\$(( \${down_map["\$user"]:-0} + val ))
    fi
  done <<< "\$raw"
  for user in \$(echo "\${!up_map[@]} \${!down_map[@]}" | tr ' ' '\n' | sort -u); do
    local up="\${up_map[\$user]:-0}" dn="\${down_map[\$user]:-0}"
    (( up + dn == 0 )) && continue
    [ \$first -eq 0 ] && json+=","
    json+="{\"username\":\"\$user\",\"upload_bytes\":\$up,\"download_bytes\":\$dn}"
    first=0
  done
  json+=']}' 
  [ \$first -eq 0 ] && { echo "[\${TS}] [XRAY] Envoi stats..."; send_stats "\$json"; } || echo "[\${TS}] [XRAY] Aucune stat"
}

# ── V2RAY ────────────────────────────────────────────────────
collect_v2ray() {
  [ ! -x "\$V2RAY_BIN" ] && return
  local raw
  raw=\$("\$V2RAY_BIN" api statsquery --server="\$V2RAY_API" 2>/dev/null) || return
  [ -z "\$raw" ] && return
  local json='{"stats":[' first=1
  declare -A up_map down_map
  while IFS= read -r line; do
    if [[ "\$line" =~ name:\"user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link\" ]]; then
      local user="\${BASH_REMATCH[1]}" dir="\${BASH_REMATCH[2]}" val=0
      [[ "\$line" =~ value:\"([0-9]+)\" ]] && val="\${BASH_REMATCH[1]}"
      [[ "\$dir" == "up"   ]] && up_map["\$user"]=\$(( \${up_map["\$user"]:-0} + val ))
      [[ "\$dir" == "down" ]] && down_map["\$user"]=\$(( \${down_map["\$user"]:-0} + val ))
    fi
  done <<< "\$raw"
  for user in \$(echo "\${!up_map[@]} \${!down_map[@]}" | tr ' ' '\n' | sort -u); do
    local up="\${up_map[\$user]:-0}" dn="\${down_map[\$user]:-0}"
    (( up + dn == 0 )) && continue
    [ \$first -eq 0 ] && json+=","
    json+="{\"username\":\"\$user\",\"upload_bytes\":\$up,\"download_bytes\":\$dn}"
    first=0
  done
  json+=']}' 
  [ \$first -eq 0 ] && send_stats "\$json" || echo "[\${TS}] [V2RAY] Aucune stat"
}

# ── SSH : delta via KIGHMU_SSH + CONNMARK ────────────────────
# Les règles iptables sont créées par server.js (sshIptablesAdd)
# à chaque création d'un user SSH, et par auto-clean.sh au démarrage.
# Ici on lit uniquement le delta depuis la dernière exécution.
collect_ssh() {
  [ ! -f "\$USER_FILE" ] && return
  command -v iptables &>/dev/null || return

  # Vérifier que la chaîne KIGHMU_SSH existe
  if ! iptables -L KIGHMU_SSH 2>/dev/null | grep -q "Chain KIGHMU_SSH"; then
    echo "[\${TS}] [SSH] Chaine KIGHMU_SSH absente — en attente init par auto-clean.sh"
    return
  fi

  local json='{"stats":[' first=1 has_data=0

  while IFS='|' read -r username _rest; do
    [ -z "\$username" ] && continue
    local uid
    uid=\$(id -u "\$username" 2>/dev/null) || continue

    # Lire compteur OUTPUT actuel (download client)
    local cur_out=0
    cur_out=\$(iptables -nvx -L KIGHMU_SSH 2>/dev/null \\
      | awk -v uid="\$uid" '
          /uid-owner/ && (\$0 ~ "uid-owner " uid " " || \$0 ~ "uid-owner " uid "\$") {sum+=\$2}
          END {print sum+0}')

    # Lire compteur INPUT actuel (upload client via CONNMARK)
    local hex_mark cur_in=0
    hex_mark=\$(printf '0x%x' "\$uid")
    cur_in=\$(iptables -nvx -L INPUT 2>/dev/null \\
      | awk -v mark="\$hex_mark" '/connmark/ && \$0 ~ "mark match " mark {sum+=\$2} END{print sum+0}')

    # Lire valeurs précédentes
    local prev_out=0 prev_in=0
    [ -f "\${DELTA_DIR}/\${username}.out" ] && prev_out=\$(< "\${DELTA_DIR}/\${username}.out")
    [ -f "\${DELTA_DIR}/\${username}.in"  ] && prev_in=\$(<  "\${DELTA_DIR}/\${username}.in")

    # Calcul delta (protection reset compteur au reboot)
    local delta_out delta_in
    (( cur_out >= prev_out )) && delta_out=\$(( cur_out - prev_out )) || delta_out=\$cur_out
    (( cur_in  >= prev_in  )) && delta_in=\$((  cur_in  - prev_in  )) || delta_in=\$cur_in

    # Sauvegarder les valeurs actuelles pour la prochaine fois
    echo "\$cur_out" > "\${DELTA_DIR}/\${username}.out"
    echo "\$cur_in"  > "\${DELTA_DIR}/\${username}.in"

    (( delta_out + delta_in == 0 )) && continue

    # upload_bytes  = données envoyées par client = INPUT serveur  (delta_in)
    # download_bytes = données reçues par client  = OUTPUT serveur (delta_out)
    [ \$first -eq 0 ] && json+=","
    json+="{\"username\":\"\${username}\",\"upload_bytes\":\${delta_in},\"download_bytes\":\${delta_out}}"
    first=0
    has_data=1
    echo "[\${TS}] [SSH-DELTA] \$username up:\${delta_in}B down:\${delta_out}B"
  done < "\$USER_FILE"

  json+=']}' 
  [ \$has_data -eq 1 ] && send_stats "\$json" || echo "[\${TS}] [SSH] Aucun trafic SSH"
}

echo "[\${TS}] === Collecte trafic KIGHMU démarrée ==="
collect_xray
collect_v2ray
collect_ssh
echo "[\${TS}] === Terminé ==="
TRAFFIC_EOF

  chmod +x "$TRAFFIC_SCRIPT"

  # ── Ajouter le cron (toutes les 2 minutes) ────────────────
  local cron_line="*/2 * * * * $TRAFFIC_SCRIPT >> $TRAFFIC_LOG 2>&1"
  crontab -l 2>/dev/null | grep -v "$TRAFFIC_SCRIPT" | crontab - 2>/dev/null || true
  ( crontab -l 2>/dev/null; echo "$cron_line" ) | crontab -

  # ── Ajouter le cron Auto-clean.sh (toutes les 10 minutes) ──
  local autoclean_script="/root/Kighmu/Auto-clean.sh"
  local autoclean_log="/var/log/auto-clean.log"
  if [[ -f "$autoclean_script" ]]; then
    local autoclean_cron="*/10 * * * * $autoclean_script >> $autoclean_log 2>&1"
    crontab -l 2>/dev/null | grep -v "$autoclean_script" | crontab - 2>/dev/null || true
    ( crontab -l 2>/dev/null; echo "$autoclean_cron" ) | crontab -
    [[ "$silent" != "silent" ]] && ok "Cron Auto-clean.sh configuré (toutes les 10 min)"
  fi

  # Créer le fichier log
  touch "$TRAFFIC_LOG"
  chmod 640 "$TRAFFIC_LOG"

  if [[ "$silent" != "silent" ]]; then
    ok "Script déployé : $TRAFFIC_SCRIPT"
    ok "Cron configuré : toutes les 2 minutes"
    ok "Logs : $TRAFFIC_LOG"
  fi
}

# ================================================================
# MENU COLLECTE TRAFIC
# ================================================================
menu_traffic() {
  while true; do
    banner
    echo -e "  ${B}COLLECTE DE TRAFIC VPN${NC}"
    echo ""

    # Statut actuel
    if [[ -f "$TRAFFIC_SCRIPT" ]]; then
      echo -e "  ${G}[✓]${NC} Script installé : ${C}$TRAFFIC_SCRIPT${NC}"
    else
      echo -e "  ${R}[✗]${NC} Script non installé"
    fi

    if crontab -l 2>/dev/null | grep -q "$TRAFFIC_SCRIPT"; then
      echo -e "  ${G}[✓]${NC} Cron actif (toutes les 2 min)"
    else
      echo -e "  ${R}[✗]${NC} Cron non configuré"
    fi
    if systemctl is-active --quiet kighmu-bandwidth 2>/dev/null; then
      echo -e "  ${G}[✓]${NC} Service bandwidth actif (boucle 5s)"
    else
      echo -e "  ${R}[✗]${NC} Service bandwidth non actif"
    fi

    if [[ -f "$TRAFFIC_LOG" ]]; then
      local last_line
      last_line=$(tail -1 "$TRAFFIC_LOG" 2>/dev/null)
      echo -e "  ${C}[i]${NC} Dernier log : ${last_line:-(vide)}"
    fi

    echo ""
    echo -e "  ${G}[1]${NC}  ▶   Installer / Réinstaller le script + cron"
    echo -e "  ${C}[2]${NC}  ▷   Lancer une collecte manuellement maintenant"
    echo -e "  ${C}[3]${NC}  📄  Voir les derniers logs de collecte (50 lignes)"
    echo -e "  ${R}[4]${NC}  ✕   Désactiver la collecte (supprimer cron + script)"
    echo -e "  ${Y}[0]${NC}  ←   Retour au menu principal"
    echo ""
    sep
    echo ""
    read -rp "  $(echo -e "${B}Votre choix : ${NC}")" choice

    case "$choice" in
      1)
        banner
        echo -e "  ${B}Installation du script de collecte...${NC}"
        echo ""
        setup_bandwidth_service
        setup_traffic_cron
        echo ""
        sep
        pause
        ;;
      2)
        if [[ -x "$TRAFFIC_SCRIPT" ]]; then
          banner
          echo -e "  ${B}Collecte manuelle en cours...${NC}"
          echo ""
          bash "$TRAFFIC_SCRIPT"
          echo ""
          sep
          pause
        else
          warn "Script non installé. Utilisez l'option [1] d'abord."
          sleep 2
        fi
        ;;
      3)
        banner
        echo -e "  ${B}LOGS DE COLLECTE (50 dernières lignes)${NC}"
        echo ""
        if [[ -f "$TRAFFIC_LOG" ]]; then
          tail -50 "$TRAFFIC_LOG"
        else
          warn "Aucun log disponible ($TRAFFIC_LOG introuvable)"
        fi
        echo ""
        sep
        pause
        ;;
      4)
        if confirm "Désactiver la collecte de trafic (supprimer cron + script + service) ?"; then
          crontab -l 2>/dev/null | grep -v "$TRAFFIC_SCRIPT" | crontab - 2>/dev/null || true
          rm -f "$TRAFFIC_SCRIPT"
          systemctl stop kighmu-bandwidth 2>/dev/null || true
          systemctl disable kighmu-bandwidth 2>/dev/null || true
          rm -f "$BANDWIDTH_SERVICE" "$BANDWIDTH_SCRIPT"
          systemctl daemon-reload 2>/dev/null || true
          ok "Collecte désactivée (cron + service bandwidth)"
        fi
        sleep 1
        ;;
      0) return ;;
      *) warn "Option invalide."; sleep 1 ;;
    esac
  done
}

# ================================================================
# POINT D'ENTRÉE
# ================================================================
[[ $EUID -ne 0 ]] && {
  echo -e "${R}[✗] Ce script doit être exécuté en root.${NC}"
  echo -e "    Utilisez : ${Y}sudo bash install.sh${NC}"
  exit 1
}

# ================================================================
# Lancement
# ================================================================
if [[ -n "$AUTO_INSTALL" ]]; then
  export DEBIAN_FRONTEND=noninteractive
  MODE="${AUTO_MODE:-domain}"
  DOMAIN="${AUTO_DOMAIN:-}"
  ADMIN_USER="${AUTO_USER:-admin}"
  ADMIN_PASS="${AUTO_PASS:-$(< /dev/urandom tr -dc 'a-zA-Z0-9@#_-' | head -c 16)}"

  if [[ -z "$DOMAIN" ]]; then
    echo "ERREUR: AUTO_DOMAIN requis"
    exit 1
  fi

  if [[ "$MODE" == "domain" ]]; then
    USE_TLS=1
    ACCESS_URL="https://${DOMAIN}:${NGINX_PORT_TLS}"
  else
    USE_TLS=0
    ACCESS_URL="http://${DOMAIN}:${NGINX_PORT}"
  fi

  do_install
  exit $?
fi

main_menu
