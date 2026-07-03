#!/bin/bash
set -euo pipefail

# ==============================
# VARIABLES
# ==============================
DROPBEAR_DIR="/etc/dropbear"
DROPBEAR_PORT=109
DROPBEAR_BANNER="/etc/dropbear/banner.txt"
SYSTEMD_FILE="/etc/systemd/system/dropbear-custom.service"
DROPBEAR_VERSION_MIN="2022.83"

# ============================== 2019.78
# DETECTION VERSION OS
# ==============================
source /etc/os-release
OS_ID="$ID"
OS_VERSION="$VERSION_ID"

# ==============================
# COULEURS
# ==============================
RED='\u001B[0;31m'
GREEN='\u001B[0;32m'
YELLOW='\u001B[1;33m'
NC='\u001B[0m'

info(){ echo -e "${GREEN}[INFO]${NC} $1"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $1"; }
error(){ echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ==============================
# ROOT CHECK
# ==============================
[ "$EUID" -ne 0 ] && { error "Exécuter en root"; }

# ==============================
# INSTALL DEPENDANCES
# ==============================
info "Mise à jour et installation des dépendances..."
apt update -y
apt install -y build-essential bzip2 zlib1g-dev wget tar dos2unix

# ==============================
# DROPBEAR INSTALL / COMPILE
# ==============================
NEED_COMPILE=false

if command -v dropbear >/dev/null 2>&1; then
    EXIST_VER=$(dropbear -V 2>&1 | awk '{print $2}' | tr -d 'v')
    if dpkg --compare-versions "$EXIST_VER" lt "$DROPBEAR_VERSION_MIN"; then
        warn "Version Dropbear ($EXIST_VER) trop ancienne. Compilation requise."
        NEED_COMPILE=true
    else
        info "Dropbear version $EXIST_VER déjà OK."
    fi
else
    info "Dropbear absent, compilation requise."
    NEED_COMPILE=true
fi

if [ "$NEED_COMPILE" = true ]; then
    info "Téléchargement et compilation Dropbear $DROPBEAR_VERSION_MIN..."
    mkdir -p /usr/local/src
    cd /usr/local/src
    wget -q "https://matt.ucc.asn.au/dropbear/releases/dropbear-$DROPBEAR_VERSION_MIN.tar.bz2"
    tar -xjf "dropbear-$DROPBEAR_VERSION_MIN.tar.bz2"
    cd "dropbear-$DROPBEAR_VERSION_MIN"
    ./configure --prefix=/usr/local
    make && make install
    info "Dropbear compilé et installé dans /usr/local/"
fi

# ==============================
# DETECTION BINAIRE ROBUSTE (FIX DEFINITIF)
# ==============================
# Recherche dropbear (priorité compilé > système)
for path in /usr/local/sbin/dropbear /usr/local/bin/dropbear /usr/sbin/dropbear /usr/bin/dropbear; do
    if [ -x "$path" ]; then
        DROPBEAR_BIN="$path"
        break
    fi
done

# Recherche dropbearkey (priorité compilé > système)
for path in /usr/local/bin/dropbearkey /usr/local/sbin/dropbearkey /usr/bin/dropbearkey /usr/sbin/dropbearkey; do
    if [ -x "$path" ]; then
        DROPBEARKEY="$path"
        break
    fi
done

# Vérification finale
[ -z "${DROPBEAR_BIN:-}" ] && error "dropbear introuvable !"
[ -z "${DROPBEARKEY:-}" ] && error "dropbearkey introuvable !"

info "✅ dropbear: $DROPBEAR_BIN ($(dropbear -V 2>&1 | head -n1))"
info "✅ dropbearkey: $DROPBEARKEY"

# Test dropbearkey (sans -V qui n'existe pas !)
"$DROPBEARKEY" -t rsa -f /dev/null >/dev/null 2>&1 || warn "dropbearkey test échoué (continu)"

# ==============================
# STOP ANCIEN SERVICE
# ==============================
info "🛑 Arrêt services Dropbear existants..."
systemctl stop dropbear dropbear.service dropbear-custom.service 2>/dev/null || true
systemctl disable dropbear dropbear.service dropbear-custom.service 2>/dev/null || true

# ==============================
# CREATION CLES
# ==============================
info "🔐 Préparation clés host Dropbear..."
mkdir -p "$DROPBEAR_DIR"
chmod 755 "$DROPBEAR_DIR"

for key in rsa ecdsa ed25519; do
    KEY_FILE="$DROPBEAR_DIR/dropbear_${key}_host_key"
    if [ ! -f "$KEY_FILE" ]; then
        info "Génération clé $key..."
        if "$DROPBEARKEY" -t "$key" -f "$KEY_FILE"; then
            info "✅ Clé $key OK"
        else
            warn "❌ Clé $key échouée"
            rm -f "$KEY_FILE"
        fi
    fi
done

# Vérif critique (au moins 1 clé)
if ! ls "$DROPBEAR_DIR"/*_host_key >/dev/null 2>&1; then
    error "AUCUNE clé host générée !"
fi

chmod 600 "$DROPBEAR_DIR"/*_host_key
chown root:root "$DROPBEAR_DIR"/*_host_key
info "Clés prêtes: $(ls "$DROPBEAR_DIR"/*_host_key 2>/dev/null | xargs -n1 basename)"

# ==============================
# BANNER + SYSTEMD
# ==============================
info "📄 Création banner..."
cat > "$DROPBEAR_BANNER" <<EOF
Dropbear SSH Server - $(hostname)
Ubuntu $OS_VERSION | Port: $DROPBEAR_PORT
EOF
chmod 644 "$DROPBEAR_BANNER"

info "⚙️  Service systemd..."
cat > "$SYSTEMD_FILE" <<EOF
[Unit]
Description=Dropbear Custom (port $DROPBEAR_PORT)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DROPBEAR_BIN -F -E -p $DROPBEAR_PORT -w -g -b $DROPBEAR_BANNER -R
Restart=always
RestartSec=2
User=root
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dropbear-custom.service

# ==============================
# NFTABLES - table dédiée dropbear
# ==============================
info "🔥 Configuration nftables (port $DROPBEAR_PORT)..."
/usr/local/bin/init-nftables.sh

TMP_NFT=$(mktemp)
cat > "$TMP_NFT" << EOF
table inet dropbear {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport $DROPBEAR_PORT accept
    }
}
EOF

if nft -c -f "$TMP_NFT"; then
    mv "$TMP_NFT" /etc/nftables/dropbear.nft
    systemctl daemon-reload
    systemctl enable --now nftables-tunnel@dropbear.service
    systemctl restart nftables-tunnel@dropbear.service
    info "✅ Table nftables dropbear chargée et persistée"
else
    warn "❌ Erreur de syntaxe nftables — table dropbear non appliquée"
    rm -f "$TMP_NFT"
fi

# ==============================
# VERIF FINALE
# ==============================
sleep 3
if systemctl is-active --quiet dropbear-custom.service; then
    if ss -tulpn | grep -q ":$DROPBEAR_PORT "; then
        info "🎉 ✅ DROPBEAR OK port $DROPBEAR_PORT !"
        info "🔗 Test: ssh -p $DROPBEAR_PORT root@$(hostname -I | awk '{print $1}')"
    else
        warn "⚠️ Service OK mais port fermé (firewall?)"
    fi
else
    error "❌ Service KO !"
    systemctl status dropbear-custom.service --no-pager
fi

info "📋 systemctl status dropbear-custom.service"
info "📋 journalctl -u dropbear-custom.service -f"
