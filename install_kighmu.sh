#!/usr/bin/env bash
# ==============================================
# Kighmu VPS Manager - Script d'installation
# Copyright (c) 2025 Kinf744
# Licence MIT (version française)
# ==============================================

set -o nounset
set -o pipefail

# ==========================================================
# CORRECTIF: Assurer DNS/réseau fonctionnel dès le départ
# ==========================================================
ensure_dns() {
    echo "⚙️  Vérification DNS/réseau avant installation..."

    # 1. Vérifier connectivité internet basique
    if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null; then
        echo "❌ Pas de connectivité réseau (ping 8.8.8.8 échoue)"
        echo "   Vérifiez votre interface réseau: ip route show"
        exit 1
    fi
    echo "✅ Connectivité réseau OK"

    # 2. Démarrer systemd-resolved si nécessaire
    if systemctl list-unit-files systemd-resolved.service &>/dev/null; then
        if ! systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            echo "⚠️  systemd-resolved inactif — démarrage..."
            systemctl start systemd-resolved 2>/dev/null || true
            systemctl enable systemd-resolved 2>/dev/null || true
            sleep 2
        fi
    fi

    # 3. Vérifier/réparer le lien symbolique resolv.conf
    if [[ ! -e /etc/resolv.conf ]]; then
        echo "⚠️  /etc/resolv.conf absent — création..."
        if [[ -f /run/systemd/resolve/stub-resolv.conf ]]; then
            ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        else
            echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
        fi
        sleep 1
    fi

    # 4. Tester la résolution DNS
    if ! getent hosts github.com &>/dev/null; then
        echo "⚠️  Résolution DNS échoue — basculement sur DNS statique..."
        rm -f /etc/resolv.conf
        echo -e "nameserver 8.8.8.8\nnameserver 1.1.1.1" > /etc/resolv.conf
        sleep 1
        if ! getent hosts github.com &>/dev/null; then
            echo "❌ DNS toujours non fonctionnel après réparation. Abandon."
            exit 1
        fi
        echo "✅ DNS réparé (8.8.8.8 / 1.1.1.1)"
    fi

    echo "✅ DNS/réseau opérationnel"
}

# AJOUTER CETTE LIGNE :
ensure_dns    # <--- ICI, appelez la fonction

echo "Vérification et installation de curl si nécessaire..."

install_package_if_missing() {
  local pkg=$1
  echo "Installation de $pkg..."
  set +e
  apt-get install -y "$pkg"
  if [[ $? -ne 0 ]]; then
    echo "⚠️ Attention : échec de l'installation du paquet $pkg, le script continue..."
  else
    echo "Le paquet $pkg a été installé avec succès."
  fi
  set -e
}

apt-get update -y
apt-get install dnsutils -y

install_package_if_missing "curl"

echo "+--------------------------------------------+"
echo "|             INSTALLATION VPS               |"
echo "+--------------------------------------------+"

read -r -p "Veuillez entrer votre nom de domaine (doit pointer vers l'IP de ce serveur) : " DOMAIN

if [[ -z "$DOMAIN" ]]; then
  echo "Erreur : vous devez entrer un nom de domaine valide."
  exit 1
fi

# ==== Détection IPv4 / IPv6 publique ====
IPV4_PUBLIC=$(curl -4 -s https://api.ipify.org || true)
IPV6_PUBLIC=$(curl -6 -s https://api6.ipify.org || true)

if [[ -n "$IPV4_PUBLIC" ]]; then
  echo "IPv4 publique détectée : $IPV4_PUBLIC"
else
  echo "Aucune IPv4 publique détectée (serveur peut être IPv6-only)."
fi

if [[ -n "$IPV6_PUBLIC" ]]; then
  echo "IPv6 publique détectée : $IPV6_PUBLIC"
else
  echo "Aucune IPv6 publique détectée (serveur peut être IPv4-only)."
fi

if [[ -z "$IPV4_PUBLIC" && -z "$IPV6_PUBLIC" ]]; then
  echo "Erreur : impossible de détecter une IP publique (ni IPv4 ni IPv6)."
  exit 1
fi

# ==== Vérification DNS du domaine (A / AAAA) ====
DOMAIN_A=$(dig +short A "$DOMAIN" | tail -n1 || true)
DOMAIN_AAAA=$(dig +short AAAA "$DOMAIN" | tail -n1 || true)

echo "Enregistrement A    (IPv4)  du domaine : ${DOMAIN_A:-aucun}"
echo "Enregistrement AAAA (IPv6)  du domaine : ${DOMAIN_AAAA:-aucun}"

MISMATCH=true

# Cas IPv4 : si le serveur a une IPv4 publique, on vérifie le A
if [[ -n "$IPV4_PUBLIC" ]]; then
  if [[ "$DOMAIN_A" == "$IPV4_PUBLIC" ]]; then
    MISMATCH=false
  fi
fi

# Cas IPv6 : si le serveur a une IPv6 publique, on vérifie le AAAA
if [[ -n "$IPV6_PUBLIC" ]]; then
  if [[ "$DOMAIN_AAAA" == "$IPV6_PUBLIC" ]]; then
    MISMATCH=false
  fi
fi

if [[ "$MISMATCH" == true ]]; then
  echo "Attention : le domaine $DOMAIN ne pointe pas vers l'IP de ce serveur."
  echo "Vérifiez les enregistrements A (IPv4) et/ou AAAA (IPv6) selon votre configuration."
  read -r -p "Voulez-vous continuer quand même ? [oui/non] : " choix
  if [[ ! "$choix" =~ ^(o|oui)$ ]]; then
    echo "Installation arrêtée."
    exit 1
  fi
fi

export DOMAIN

echo "=============================================="
echo " 🚀 Installation des paquets essentiels..."
echo "=============================================="

install_package_if_missing "sudo"
install_package_if_missing "bsdmainutils"
install_package_if_missing "zip"
install_package_if_missing "unzip"
install_package_if_missing "curl"
install_package_if_missing "python3"
install_package_if_missing "python3-pip"
install_package_if_missing "openssl"
install_package_if_missing "screen"
install_package_if_missing "cron"
install_package_if_missing "iptables"
install_package_if_missing "lsof"
install_package_if_missing "pv"
install_package_if_missing "nano"
install_package_if_missing "at"
install_package_if_missing "gawk"
install_package_if_missing "grep"
install_package_if_missing "bc"
install_package_if_missing "jq"
install_package_if_missing "npm"
install_package_if_missing "nodejs"
install_package_if_missing "socat"
install_package_if_missing "netcat-openbsd"
install_package_if_missing "net-tools"
install_package_if_missing "cowsay"
install_package_if_missing "figlet"
install_package_if_missing "dnsutils"
install_package_if_missing "wget"
install_package_if_missing "psmisc"
install_package_if_missing "python3-setuptools"
install_package_if_missing "qrencode"
install_package_if_missing "gcc"
install_package_if_missing "make"
install_package_if_missing "perl"
install_package_if_missing "systemd"
install_package_if_missing "tcpdump"
install_package_if_missing "iptables"
install_package_if_missing "iproute2"
install_package_if_missing "net-tools"
install_package_if_missing "tmux"
install_package_if_missing "git"
install_package_if_missing "vnstat"
install_package_if_missing "chrony"
install_package_if_missing "iptables-persistent"
install_package_if_missing "build-essential"
install_package_if_missing "libssl-dev"
install_package_if_missing "software-properties-common"

apt autoremove -y
apt clean

echo "=============================================="
echo " 🚀 Installation de Kighmu VPS Manager..."
echo "=============================================="

INSTALL_DIR="$HOME/Kighmu"
mkdir -p "$INSTALL_DIR"

FILES=(
  "install_kighmu.sh"
  "kighmu-manager.sh"
  "kighmu.sh"
  "menu1.sh"
  "menu2.sh"
  "menu3.sh"
  "menu_4.sh"
  "menu4.sh"
  "menu5.sh"
  "menu6.sh"
  "menu7.sh"
  "slowdns.sh"
  "socks_python.sh"
  "udp_custom.sh"
  "dropbear.sh"
  "proxy3.js"
  "ws_tt_ssl.sh"
  "system_dns.sh"
  "install_modes.sh"
  "show_resources.sh"
  "setup_ssh_config.sh"
  "menu4_2.sh"
  "botssh.sh"
  "menu_6.sh"
  "xray_installe.sh"
  "ws_wss_server.py"
  "proxy--ws.sh"
  "sockspy.sh"
  "ws2_proxy.py"
  "menu_5.sh"
  "sshws.go"
  "ssl_tls.go"
  "bot2.go"
  "bot2_pannel.sh"
  "Delete_user_xray.sh"
  "xray-quota.go"
  "xray-quota-panel.sh"
  "install_v2ray.sh"
  "sirust.sh"
  "Hysteria1.sh"
  "Auto-clean.sh"
  "install-1.sh"
  "schema.sql"
  "admin.html"
  "reseller.html"
  "server.js"
  "kighmu-server.sh"
  "index.html"
  "vless_bot.py"
)

BASE_URL="https://raw.githubusercontent.com/kinf744/Kighmu/main"

for file in "${FILES[@]}"; do
  echo "Téléchargement de $file ..."
  wget -q --show-progress -O "$INSTALL_DIR/$file" "$BASE_URL/$file"
  if [[ ! -s "$INSTALL_DIR/$file" ]]; then
    echo "⚠️ Erreur : le fichier $file n'a pas été téléchargé correctement ou est vide, mais le script continue..."
  else
    chmod +x "$INSTALL_DIR/$file"
  fi
done

# ==========================================
# Configuration du nettoyage automatique
# ==========================================

echo "Configuration du nettoyage automatique des utilisateurs expirés..."

CLEAN_SCRIPT="$INSTALL_DIR/Auto-clean.sh"

if [[ -f "$CLEAN_SCRIPT" ]]; then
  chmod +x "$CLEAN_SCRIPT"

  CRON_JOB="*/10 * * * * $CLEAN_SCRIPT >> /var/log/auto-clean.log 2>&1"

  # Vérifie si le cron existe déjà
  if crontab -l 2>/dev/null | grep -Fq "$CLEAN_SCRIPT"; then
      echo "Cron déjà configuré pour le nettoyage automatique."
  else
      # Ajoute le cron même si crontab est vide
      ( crontab -l 2>/dev/null; echo "$CRON_JOB" ) | crontab -
      echo "Cron ajouté pour le nettoyage automatique (exécution quotidienne à minuit)."
  fi

  # Active et redémarre le service cron
  systemctl enable cron >/dev/null 2>&1
  systemctl restart cron >/dev/null 2>&1
else
  echo "⚠️ Auto-clean.sh introuvable, cron non configuré."
fi

# Création du fichier ~/.kighmu_info avec les infos globales nécessaires
: "${NS:=}"
: "${PUBLIC_KEY:=}"

cat > ~/.kighmu_info <<EOF
DOMAIN=$DOMAIN
NS=$NS
PUBLIC_KEY="$PUBLIC_KEY"
EOF

chmod 600 ~/.kighmu_info
echo "Fichier ~/.kighmu_info créé avec succès et permissions sécurisées."

run_script() {
  local script_path=$1
  echo "🚀 Lancement du script : $script_path"
  set +e
  bash "$script_path"
  if [[ $? -ne 0 ]]; then
    echo "⚠️ Attention : $script_path a rencontré une erreur, mais l'installation continue..."
  else
    echo "✅ $script_path exécuté avec succès."
  fi
  set -e
}

echo "🚀 Application de la configuration SSH personnalisée..."
chmod +x "$INSTALL_DIR/setup_ssh_config.sh"
run_script "sudo $INSTALL_DIR/setup_ssh_config.sh"

echo "🚀 Script de création utilisateur SSH disponible : $INSTALL_DIR/create_ssh_user.sh"
echo "Tu peux le lancer manuellement quand tu veux."

if ! grep -q "alias kighmu=" ~/.bashrc; then
  echo "alias kighmu='$INSTALL_DIR/kighmu.sh'" >> ~/.bashrc
  echo "Alias kighmu ajouté dans ~/.bashrc"
fi

if ! grep -q "/usr/local/bin" ~/.bashrc; then
  echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
  echo "Ajout de /usr/local/bin au PATH dans ~/.bashrc"
fi

# Création du script kighmu-panel.sh dans /usr/local/bin
cat > /usr/local/bin/kighmu-panel.sh << 'EOF'
#!/bin/bash

clear

RED='\u001B[0;31m'
YELLOW='\u001B[0;33m'
GREEN='\u001B[0;32m'
CYAN='\u001B[0;36m'
NC='\u001B[0m'

echo -e "${RED}
K   K  III  GGG  H   H M   M U   U     V   V PPPP   SSS
K  K    I  G     H   H MM MM U   U     V   V P   P S
KKK     I  G  GG HHHHH M M M U   U     V   V PPPP   SSS
K  K    I  G   G H   H M   M U   U      V V  P         S
K   K  III  GGG  H   H M   M  UUU        V   P      SSS
${NC}"

echo
echo -e "Saisir et valider: ${YELLOW}source ~/.bashrc${NC}"

echo -e "${GREEN}Version du script : 2.5${NC}"
echo -e "${CYAN}Inbox Telegramme : @KIGHMU${NC}"
echo
echo -e "Pour ouvrir le panneau de contrôle principal, tapez : ${YELLOW}kighmu${NC}"
echo
EOF

chmod +x /usr/local/bin/kighmu-panel.sh

# Ajout automatique au démarrage du shell du panneau avec nettoyage écran
if ! grep -q "kighmu-panel.sh" ~/.bashrc; then
  echo -e "
# Affichage automatique du panneau KIGHMU au démarrage
clear
/usr/local/bin/kighmu-panel.sh
" >> ~/.bashrc
fi

# Lancement immédiat une fois après installation
/usr/local/bin/kighmu-panel.sh
