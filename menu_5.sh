#!/bin/bash

# Fichier stockage utilisateurs (V2Ray)
USER_DB="/etc/v2ray/utilisateurs.json"

mkdir -p /etc/v2ray
touch "$USER_DB"
chmod 600 "$USER_DB"

# Initialiser JSON si corrompu ou vide
if ! jq empty "$USER_DB" >/dev/null 2>&1; then
    echo "[]" > "$USER_DB"
fi

# Couleurs ANSI pour mise en forme
CYAN="\u001B[1;36m"
YELLOW="\u001B[1;33m"
GREEN="\u001B[1;32m"
RED="\u001B[1;31m"
WHITE="\u001B[1;37m"
RESET="\u001B[0m"

# === Configuration SlowDNS (DNS-AGN) ===
SLOWDNS_DIR="/etc/slowdns_v2ray"
SLOWDNS_BIN="/usr/local/bin/dns-server"
PORT=5400
CONFIG_FILE="$SLOWDNS_DIR/ns.conf"
SERVER_KEY="$SLOWDNS_DIR/server.key"
SERVER_PUB="$SLOWDNS_DIR/server.pub"

charger_utilisateurs() {
    if [[ -f "$USER_DB" && -s "$USER_DB" ]]; then
        utilisateurs=$(cat "$USER_DB")
    else
        utilisateurs="[]"
    fi
}

sauvegarder_utilisateurs() {
    echo "$utilisateurs" > "$USER_DB"
}

# Générer lien vless au format adapter
generer_liens_v2ray() {
    local nom="$1"
    local domaine="$2"
    local port="$3"
    local uuid="$4"

    lien_vless="vless://${uuid}@${domaine}:${port}?type=tcp&encryption=none&host=${domaine}#${nom}-VLESS-TCP"
}

# ✅ AJOUTÉ: Fonction pour ajouter UUID dans V2Ray
ajouter_client_v2ray() {
    local uuid="$1"
    local nom="$2"
    local config="/etc/v2ray/config.json"

    [[ ! -f "$config" ]] && { echo "❌ config.json introuvable"; return 1; }

    # Vérification JSON AVANT
    if ! jq empty "$config" >/dev/null 2>&1; then
        echo "❌ config.json invalide AVANT modification"
        return 1
    fi

    # Vérifier doublon UUID ou email (VLESS uniquement)
    if jq -e --arg uuid "$uuid" --arg email "$nom" '
        .inbounds[]
        | select(.protocol=="vless")
        | .settings.clients[]?
        | select(.id==$uuid or .email==$email)
    ' "$config" >/dev/null 2>&1; then
        echo "⚠️ UUID ou email déjà existant"
        return 0
    fi

    tmpfile=$(mktemp)

    # Ajout UNIQUEMENT dans VLESS
    jq --arg uuid "$uuid" --arg email "$nom" '
    .inbounds |= map(
        if .protocol=="vless" then
            .settings.clients += [{"id": $uuid, "email": $email}]
        else .
        end
    )
    ' "$config" > "$tmpfile"

    # Vérification JSON APRÈS
    if ! jq empty "$tmpfile" >/dev/null 2>&1; then
        echo "❌ JSON cassé APRÈS modification"
        rm -f "$tmpfile"
        return 1
    fi

    mv "$tmpfile" "$config"

    # Test V2Ray
    if ! /usr/local/bin/v2ray test -config "$config" >/dev/null 2>&1; then
        echo "❌ V2Ray refuse la configuration"
        return 1
    fi

    systemctl restart v2ray

    if systemctl is-active --quiet v2ray; then
        echo "✅ Utilisateur ajouté (VLESS TCP)"
        return 0
    else
        echo "❌ V2Ray n’a pas redémarré"
        return 1
    fi
}

# ── Bloquer un utilisateur (quota ou expiration) ──────────────
bloquer_utilisateur() {
    local uuid="$1" nom="$2" raison="${3:-quota}"
    local config="/etc/v2ray/config.json"
    [[ ! -f "$config" ]] && return 1
    # Retirer UUID de config.json
    local tmpfile; tmpfile=$(mktemp)
    jq --arg uuid "$uuid" '
    .inbounds |= map(
        if .protocol=="vless" or .protocol=="vmess" then
            .settings.clients |= map(select(.id != $uuid))
        else . end
    )' "$config" > "$tmpfile"
    if jq empty "$tmpfile" >/dev/null 2>&1; then
        mv "$tmpfile" "$config"
        systemctl restart v2ray
        # Sauvegarder dans blocked_users.json
        local blocked; blocked=$(cat "$BLOCKED_DB" 2>/dev/null || echo "[]")
        blocked=$(echo "$blocked" | jq --arg u "$uuid" --arg n "$nom" --arg r "$raison" --arg d "$(date +%Y-%m-%d)"             '. += [{"uuid": $u, "nom": $n, "raison": $r, "date": $d}]')
        echo "$blocked" > "$BLOCKED_DB"
        echo "?? $nom bloqué ($raison)"
    else
        rm -f "$tmpfile"
    fi
}

# ── Vérifier quotas et expirations (appelé par cron) ───────────
verifier_quotas() {
    charger_utilisateurs
    local today; today=$(date +%Y-%m-%d)
    local count; count=$(echo "$utilisateurs" | jq length)
    (( count == 0 )) && return
    # Lire stats v2ray API
    local api_raw
    api_raw=$("$V2RAY_BIN" api stats --server="$V2RAY_API" -reset 2>/dev/null) || true
    declare -A used_bytes_map=()
    while IFS= read -r line; do
        if [[ "$line" =~ user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link ]]; then
            local user="${BASH_REMATCH[1]}" dir="${BASH_REMATCH[2]}"
            local bytes=0
            if [[ "$line" =~ ([0-9]+\.?[0-9]*)([KMGT]?B) ]]; then
                local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
                case "$unit" in
                    B)  bytes=$(awk "BEGIN {printf "%d", $num}") ;;
                    KB) bytes=$(awk "BEGIN {printf "%d", $num * 1024}") ;;
                    MB) bytes=$(awk "BEGIN {printf "%d", $num * 1048576}") ;;
                    GB) bytes=$(awk "BEGIN {printf "%d", $num * 1073741824}") ;;
                esac
            fi
            used_bytes_map["$user"]=$(( ${used_bytes_map["$user"]:-0} + bytes ))
        fi
    done <<< "$api_raw"
    # Accumuler used_bytes dans utilisateurs.json
    local changed=0
    for i in $(seq 0 $((count - 1))); do
        local nom uuid expire limit used
        nom=$(echo "$utilisateurs"    | jq -r ".[$i].nom")
        uuid=$(echo "$utilisateurs"   | jq -r ".[$i].uuid")
        expire=$(echo "$utilisateurs" | jq -r ".[$i].expire")
        limit=$(echo "$utilisateurs"  | jq -r ".[$i].data_limit_gb // 0")
        used=$(echo "$utilisateurs"   | jq -r ".[$i].used_bytes // 0")
        # Ajouter trafic de cette période
        local new_bytes="${used_bytes_map[$nom]:-0}"
        local total_used=$(( used + new_bytes ))
        utilisateurs=$(echo "$utilisateurs" | jq --argjson i $i --argjson b $total_used             '.[$i].used_bytes = $b')
        changed=1
        # Vérifier expiration
        if [[ "$expire" < "$today" ]]; then
            bloquer_utilisateur "$uuid" "$nom" "expiration"
            continue
        fi
        # Vérifier quota (si limit > 0)
        if (( $(echo "$limit > 0" | bc -l 2>/dev/null || echo 0) )); then
            local limit_bytes; limit_bytes=$(awk -v l="${limit}" 'BEGIN {printf "%d", l * 1073741824}' 2>/dev/null || echo "0")
            if (( total_used >= limit_bytes )); then
                bloquer_utilisateur "$uuid" "$nom" "quota"
            fi
        fi
    done
    [[ $changed -eq 1 ]] && sauvegarder_utilisateurs
}

# ── Lister tous les utilisateurs avec statut ───────────────────
lister_utilisateurs() {
    charger_utilisateurs
    local count; count=$(echo "$utilisateurs" | jq length)
    local today; today=$(date +%Y-%m-%d)
    # Lire trafic temps réel depuis API v2ray (sans -reset)
    declare -A live_bytes=()
    local api_raw
    api_raw=$("$V2RAY_BIN" api stats --server="$V2RAY_API" 2>/dev/null) || true
    while IFS= read -r line; do
        if [[ "$line" =~ user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link ]]; then
            local user="${BASH_REMATCH[1]}"
            local bytes=0
            if [[ "$line" =~ ([0-9]+\.?[0-9]*)([KMGT]?B) ]]; then
                local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
                case "$unit" in
                    B)  bytes=$(awk -v n="$num" 'BEGIN {printf "%d", n}') ;;
                    KB) bytes=$(awk -v n="$num" 'BEGIN {printf "%d", n * 1024}') ;;
                    MB) bytes=$(awk -v n="$num" 'BEGIN {printf "%d", n * 1048576}') ;;
                    GB) bytes=$(awk -v n="$num" 'BEGIN {printf "%d", n * 1073741824}') ;;
                esac
            fi
            live_bytes["$user"]=$(( ${live_bytes["$user"]:-0} + bytes ))
        fi
    done <<< "$api_raw"
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}║              LISTE DES UTILISATEURS V2RAY                    ║${RESET}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
    if (( count == 0 )); then
        echo -e "  ${YELLOW}Aucun utilisateur${RESET}"
        read -p "Entrée pour continuer..."
        return
    fi
    for i in $(seq 0 $((count - 1))); do
        local nom uuid expire limit used_bytes used_gb limit_str statut color
        nom=$(echo "$utilisateurs"       | jq -r ".[$i].nom")
        uuid=$(echo "$utilisateurs"      | jq -r ".[$i].uuid")
        expire=$(echo "$utilisateurs"    | jq -r ".[$i].expire")
        limit=$(echo "$utilisateurs"     | jq -r ".[$i].data_limit_gb // 0")
        used_bytes=$(echo "$utilisateurs"| jq -r ".[$i].used_bytes // 0")
        local live="${live_bytes[$nom]:-0}"
        local total_display=$(( used_bytes + live ))
        used_gb=$(awk -v b="${total_display}" 'BEGIN {
            if (b < 1024) printf "%.0f o", b
            else if (b < 1048576) printf "%.2f Ko", b/1024
            else if (b < 1073741824) printf "%.2f Mo", b/1048576
            else if (b < 1099511627776) printf "%.2f Go", b/1073741824
            else printf "%.2f To", b/1099511627776
        }' 2>/dev/null || echo "0 o")
        used_bytes=$total_display
        # Quota string
        if [[ "$limit" == "0" ]]; then
            limit_str="illimité"
        else
            limit_str="${used_gb} / ${limit}Go"
        fi
        # Statut
        local quota_ok=1 date_ok=1
        [[ "$expire" < "$today" ]] && date_ok=0
        if [[ "$limit" != "0" ]]; then
            local limit_bytes; limit_bytes=$(awk -v l="${limit}" 'BEGIN {printf "%d", l * 1073741824}' 2>/dev/null || echo "0")
            (( used_bytes >= limit_bytes )) && quota_ok=0
        fi
        # Vérifier si bloqué dans config.json
        local dans_config=0
        if jq -e --arg u "$uuid" '.inbounds[].settings.clients[]? | select(.id==$u)' /etc/v2ray/config.json >/dev/null 2>&1; then
            dans_config=1
        fi
        if (( date_ok && quota_ok && dans_config )); then
            statut="✅ Actif"
            color="$GREEN"
        else
            statut="❌ Non actif"
            color="$RED"
            [[ $date_ok -eq 0 ]]    && statut="❌ Expiré"
            [[ $quota_ok -eq 0 ]]   && statut="❌ Quota dépassé"
            [[ $dans_config -eq 0 ]] && statut="❌ Bloqué"
        fi
        echo -e "  ${YELLOW}$((i+1))) ${WHITE}$nom${RESET}"
        echo -e "       Expire  : ${CYAN}$expire${RESET}"
        echo -e "       Quota   : ${CYAN}$limit_str${RESET}"
        echo -e "       Statut  : ${color}$statut${RESET}"
        echo ""
    done
    read -p "Entrée pour continuer..."
}

# Affiche le menu avec titre dans cadre
afficher_menu() {
    clear
    echo -e "${CYAN}╔═════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║       V2RAY + FASTDNS TUNNEL${RESET}"
    echo -e "${YELLOW}║--------------------------------------------------${RESET}"
}

afficher_mode_v2ray_ws() {
    # 🔹 Statut du tunnel V2Ray
    if systemctl is-active --quiet v2ray.service; then
        local v2ray_port
        v2ray_port=$(jq -r '.inbounds[0].port' /etc/v2ray/config.json 2>/dev/null || echo "5401")
        echo -e "${CYAN}Tunnel V2Ray actif:${RESET}"
        echo -e "  - V2Ray TCP sur le port TCP ${GREEN}$v2ray_port${RESET}"
    else
        echo -e "${RED}Tunnel V2Ray inactif${RESET}"
    fi

    # 🔹 Statut du tunnel SlowDNS
    if systemctl is-active --quiet slowdns.service; then
        echo -e "${CYAN}Tunnel FastDNS actif:${RESET}"
        echo -e "  - FastDNS sur le port UDP ${GREEN}5400${RESET} → V2Ray 5401"
    else
        echo -e "${RED}Tunnel FastDNS inactif${RESET}"
    fi

    # 🔹 Nombre total d'utilisateurs créés
    # Lire le compteur depuis utilisateurs.json (users locaux VPS)
    # Compter utilisateurs shell (utilisateurs.json)
    if [[ -f "$USER_DB" && -s "$USER_DB" ]]; then
        nb_shell=$(jq length "$USER_DB" 2>/dev/null || echo 0)
        uuids_shell=$(jq -r '.[].uuid' "$USER_DB" 2>/dev/null || echo "")
    else
        nb_shell=0
        uuids_shell=""
    fi

    # Compter utilisateurs panel MySQL (v2ray-fastdns actifs, non expirés)
    nb_panel=0
    if command -v mysql >/dev/null 2>&1; then
        panel_uuids=$(mysql kighmu_panel -se             "SELECT uuid FROM clients WHERE tunnel_type='v2ray-fastdns' AND is_active=1 AND expires_at >= NOW();"             2>/dev/null || echo "")
        # Compter uniquement les UUIDs panel absents de utilisateurs.json (éviter doublons)
        for puuid in $panel_uuids; do
            if ! echo "$uuids_shell" | grep -q "$puuid"; then
                nb_panel=$((nb_panel + 1))
            fi
        done
    fi

    nb_utilisateurs=$((nb_shell + nb_panel))
    nb_utilisateurs=${nb_utilisateurs:-0}
    echo -e "${CYAN}Nombre total d'utilisateurs créés : ${GREEN}$nb_utilisateurs${RESET} (shell: ${nb_shell} | panel: ${nb_panel})"
}

# Affiche les options du menu
show_menu() {
    echo -e "${YELLOW}║--------------------------------------------------${RESET}"
    echo -e "${YELLOW}║ 1) Installer tunnel V2Ray WS${RESET}"
    echo -e "${YELLOW}║ 2) Créer nouvel utilisateur${RESET}"
    echo -e "${YELLOW}║ 3) Liste des utilisateurs${RESET}"
    echo -e "${YELLOW}║ 4) Supprimer un utilisateur${RESET}"
    echo -e "${YELLOW}║ 5) Désinstaller V2Ray+FastDNS${RESET}"
    echo -e "${YELLOW}║ 6) Bot telegram${RESET}"
    echo -e "${YELLOW}║ 7) Pannel Web${RESET}"
    echo -e "${YELLOW}║ 8) vless GC${RESET}"
    echo -e "${RED}║ 0) Quitter${RESET}"
    echo -e "${CYAN}╚═════════════════════════════════════════════════════╝${RESET}"
    echo -n "Choisissez une option : "
}

# Générer UUID v4
generer_uuid() {
    cat /proc/sys/kernel/random/uuid
}

basculer_mode_mix() {
    local config_src="/etc/v2ray/config-mix.json"
    local config_dst="/etc/v2ray/config.json"

    if [[ ! -f "$config_src" ]]; then
        echo "❌ $config_src introuvable. Réinstallez V2Ray."
        read -p "Appuyez sur Entrée pour continuer..."
        return 1
    fi

    echo "🔄 Test de la config MIX..."
    if ! /usr/local/bin/v2ray test -config "$config_src" >/dev/null 2>&1; then
        echo "❌ Config MIX invalide. Abandon."
        read -p "Appuyez sur Entrée pour continuer..."
        return 1
    fi

    sudo cp "$config_src" "$config_dst"
    # Réinjecter tous les clients après basculement
    python3 - << 'PYEOF'
import json, subprocess
cfg_path = "/etc/v2ray/config.json"
with open(cfg_path) as f: cfg = json.load(f)
inb = next((i for i in cfg["inbounds"] if i["protocol"] in ("vless","vmess")), None)
if inb:
    existing = {c["id"] for c in inb["settings"]["clients"]}
    added = 0
    try:
        with open("/etc/v2ray/utilisateurs.json") as f2: users = json.load(f2)
        for u in users:
            if u["uuid"] not in existing:
                inb["settings"]["clients"].append({"id": u["uuid"], "email": u["nom"]})
                existing.add(u["uuid"]); added += 1
    except: pass
    try:
        r = subprocess.run(["mysql","kighmu_panel","-se","SELECT username,uuid FROM clients WHERE tunnel_type='v2ray-fastdns';"], capture_output=True, text=True)
        for line in r.stdout.strip().split("\n")[1:]:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] not in existing:
                inb["settings"]["clients"].append({"id": parts[1], "email": parts[0]})
                existing.add(parts[1]); added += 1
    except: pass
    with open(cfg_path, "w") as f2: json.dump(cfg, f2, indent=2)
    print(f"  → {added} clients réinjectés")
PYEOF
    sudo systemctl restart v2ray

    if systemctl is-active --quiet v2ray; then
        echo "✅ Mode MIX activé (SSH + V2Ray sur 5401)"
    else
        echo "❌ V2Ray n’a pas démarré en mode MIX"
    fi
    read -p "Appuyez sur Entrée pour continuer..."
}

basculer_mode_v2only() {
    local config_src="/etc/v2ray/config-v2only.json"
    local config_dst="/etc/v2ray/config.json"

    if [[ ! -f "$config_src" ]]; then
        echo "❌ $config_src introuvable. Réinstallez V2Ray."
        read -p "Appuyez sur Entrée pour continuer..."
        return 1
    fi

    echo "🔄 Test de la config V2ONLY..."
    if ! /usr/local/bin/v2ray test -config "$config_src" >/dev/null 2>&1; then
        echo "❌ Config V2ONLY invalide. Abandon."
        read -p "Appuyez sur Entrée pour continuer..."
        return 1
    fi

    sudo cp "$config_src" "$config_dst"
    # Réinjecter tous les clients après basculement
    python3 - << 'PYEOF'
import json, subprocess
cfg_path = "/etc/v2ray/config.json"
with open(cfg_path) as f: cfg = json.load(f)
inb = next((i for i in cfg["inbounds"] if i["protocol"] in ("vless","vmess")), None)
if inb:
    existing = {c["id"] for c in inb["settings"]["clients"]}
    added = 0
    try:
        with open("/etc/v2ray/utilisateurs.json") as f2: users = json.load(f2)
        for u in users:
            if u["uuid"] not in existing:
                inb["settings"]["clients"].append({"id": u["uuid"], "email": u["nom"]})
                existing.add(u["uuid"]); added += 1
    except: pass
    try:
        r = subprocess.run(["mysql","kighmu_panel","-se","SELECT username,uuid FROM clients WHERE tunnel_type='v2ray-fastdns';"], capture_output=True, text=True)
        for line in r.stdout.strip().split("\n")[1:]:
            parts = line.split("\t")
            if len(parts) >= 2 and parts[1] not in existing:
                inb["settings"]["clients"].append({"id": parts[1], "email": parts[0]})
                existing.add(parts[1]); added += 1
    except: pass
    with open(cfg_path, "w") as f2: json.dump(cfg, f2, indent=2)
    print(f"  → {added} clients réinjectés")
PYEOF
    sudo systemctl restart v2ray

    if systemctl is-active --quiet v2ray; then
        echo "✅ Mode V2RAY ONLY activé (sans SSH sur 5401)"
    else
        echo "❌ V2Ray n’a pas démarré en mode V2ONLY"
    fi
    read -p "Appuyez sur Entrée pour continuer..."
}
    
# ✅ CORRIGÉ: Création utilisateur avec UUID auto-ajouté
creer_utilisateur() {
    local nom duree uuid date_exp domaine

    echo -n "Entrez un nom d'utilisateur : "
    read nom

    echo -n "Durée de validité (en jours) : "
    read duree

    # Vérification durée
    if ! [[ "$duree" =~ ^[0-9]+$ ]]; then
        echo "❌ Durée invalide"
        read -p "Entrée pour continuer..."
        return
    fi

    echo -n "Limite de données en Go (ex: 10.50, 0 = illimité) : "
    read data_limit
    if ! [[ "$data_limit" =~ ^[0-9]+([.][0-9]{1,2})?$ ]]; then
        echo "❌  Limite invalide (ex: 10.50 ou 0)"
        read -p "Entrée pour continuer..."
        return
    fi
    # Vérifier si utilisateur Linux existe déjà
    if id "$nom" &>/dev/null; then
        echo "❌ L'utilisateur Linux existe déjà"
        read -p "Entrée pour continuer..."
        return
    fi

    # Charger base utilisateurs
    charger_utilisateurs

    # Génération UUID et date expiration
    uuid=$(generer_uuid)
    date_exp=$(date -d "+${duree} days" +%Y-%m-%d)

    # ===============================
    useradd -m -s /bin/bash "$nom" || {
        echo "❌ Erreur création utilisateur Linux"
        read -p "Entrée pour continuer..."
        return
    }

    # Mot de passe = UUID (même logique que tes tunnels)
    echo "$nom:$uuid" | chpasswd

    # Expiration système
    chage -E "$date_exp" "$nom"

    # ===============================
    utilisateurs=$(echo "$utilisateurs" | jq --arg n "$nom" --arg u "$uuid" --arg d "$date_exp" --argjson l "${data_limit:-0}" \
        '. += [{"nom": $n, "uuid": $u, "expire": $d, "data_limit_gb": $l, "used_bytes": 0}]')

    local tmpfile=$(mktemp)
    echo "$utilisateurs" > "$tmpfile"
    mv "$tmpfile" "$USER_DB"
    chmod 600 "$USER_DB"

    # ===============================
    if [[ -f /etc/v2ray/config.json ]]; then
        if ! ajouter_client_v2ray "$uuid" "$nom"; then
            echo "❌ Erreur ajout utilisateur dans V2Ray"
            read -p "Entrée pour continuer..."
            return
        fi
    else
        echo "⚠️ V2Ray non installé – option 1 obligatoire"
        read -p "Entrée pour continuer..."
        return
    fi

    # Domaine
    if [[ -f /.v2ray_domain ]]; then
        domaine=$(cat /.v2ray_domain)
    else
        domaine="votre-domaine.com"
    fi

    local V2RAY_INTER_PORT="5401"
    local FASTDNS_PORT="${PORT:-5400}"

    # FastDNS / SlowDNS
    SLOWDNS_DIR="/etc/slowdns"
    if [[ -f "$SLOWDNS_DIR/slowdns.env" ]]; then
        source "$SLOWDNS_DIR/slowdns.env"
    fi
    local PUB_KEY=${PUB_KEY:-$( [[ -f "$SLOWDNS_DIR/server.pub" ]] && cat "$SLOWDNS_DIR/server.pub" || echo "clé_non_disponible" )}
    local NAMESERVER=${NS:-$( [[ -f "$SLOWDNS_DIR/ns.conf" ]] && cat "$SLOWDNS_DIR/ns.conf" || echo "NS_non_defini" )}

    # Génération lien V2Ray
    generer_liens_v2ray "$nom" "$domaine" "$V2RAY_INTER_PORT" "$uuid"

    # ===============================
    TODAY=$(date +%Y-%m-%d)

    # Filtrer utilisateurs valides
    utilisateurs_valides=$(echo "$utilisateurs" | jq --arg today "$TODAY" '[.[] | select(.expire >= $today)]')
    uuids_expire=$(echo "$utilisateurs" | jq --arg today "$TODAY" -r '.[] | select(.expire < $today) | .uuid')

    if [[ -f /etc/v2ray/config.json ]]; then
        tmpfile=$(mktemp)
        jq --argjson uuids "$(echo "$uuids_expire" | jq -R -s -c 'split("\n")[:-1]')" '
            .inbounds |= map(
                if .protocol=="vless" then
                    .settings.clients |= map(select(.id as $id | $uuids | index($id) | not))
                else .
                end
            )
        ' /etc/v2ray/config.json > "$tmpfile"
        mv "$tmpfile" /etc/v2ray/config.json
        systemctl restart v2ray
    fi

    # Sauvegarder uniquement les utilisateurs valides
    utilisateurs="$utilisateurs_valides"
    sauvegarder_utilisateurs

    # ===============================
    clear
    echo -e "${GREEN}============================================"
    echo -e "🧩 VLESS TCP + FASTDNS"
    echo -e "===================================================="
    echo -e "📄 Configuration pour : ${YELLOW}$nom${RESET}"
    echo -e "-------------------------------------------------------------"
    echo -e "➤ DOMAINE : ${GREEN}$domaine${RESET}"
    echo -e "➤ PORTS :"
    echo -e "   FastDNS UDP: ${GREEN}$FASTDNS_PORT${RESET}"
    echo -e "   V2Ray TCP  : ${GREEN}$V2RAY_INTER_PORT${RESET}"
    echo -e "➤ UUID / Password : ${GREEN}$uuid${RESET}"
    echo -e "➤ Validité : ${YELLOW}$duree${RESET} jours (expire: $date_exp)"
    if [[ "$data_limit" == "0" ]]; then
        echo -e "➤ Quota    : ${GREEN}Illimité${RESET}"
    else
        echo -e "➤ Quota    : ${GREEN}${data_limit} Go${RESET}"
    fi
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━  CONFIGS SLOWDNS PORT 5400 ━━━━━━━━━━━━━●"
    echo -e "${CYAN}Clé publique FastDNS:${RESET}"
    echo -e "$PUB_KEY"
    echo -e "${CYAN}NameServer:${RESET} $NAMESERVER"
    echo ""
    echo -e "${GREEN}●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●"
    echo -e "${YELLOW}┃ Lien VLESS  : $lien_vless${RESET}"
    echo -e "${GREEN}●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●"
    echo ""

    read -p "Appuyez sur Entrée pour continuer..."
}

supprimer_utilisateur() {
    charger_utilisateurs
    count=$(echo "$utilisateurs" | jq length)

    if [ "$count" -eq 0 ]; then
        echo "Aucun utilisateur à supprimer."
        read -p "Appuyez sur Entrée pour continuer..."
        return
    fi

    echo "Utilisateurs actuels :"
    for i in $(seq 0 $((count - 1))); do
        nom=$(echo "$utilisateurs" | jq -r ".[$i].nom")
        expire=$(echo "$utilisateurs" | jq -r ".[$i].expire")
        uuid=$(echo "$utilisateurs" | jq -r ".[$i].uuid")
        echo "$((i+1))) $nom | expire le $expire | UUID: $uuid"
    done

    echo -n "Numéro à supprimer : "
    read choix

    if (( choix < 1 || choix > count )); then
        echo "Choix invalide."
        read -p "Appuyez sur Entrée pour continuer..."
        return
    fi

    index=$((choix - 1))
    uuid_supprime=$(echo "$utilisateurs" | jq -r ".[$index].uuid")
    nom_supprime=$(echo "$utilisateurs" | jq -r ".[$index].nom")

    # 🔴 Suppression dans la base utilisateurs
    utilisateurs=$(echo "$utilisateurs" | jq "del(.[${index}])")
    sauvegarder_utilisateurs

    # 🔴 Suppression dans V2Ray (VLESS uniquement)
    if [[ -f /etc/v2ray/config.json ]]; then
        tmpfile=$(mktemp)

        jq --arg uuid "$uuid_supprime" '
        .inbounds |= map(
            if .protocol=="vless" then
                .settings.clients |= map(select(.id != $uuid))
            else .
            end
        )
        ' /etc/v2ray/config.json > "$tmpfile"

        if jq empty "$tmpfile" >/dev/null 2>&1; then
            mv "$tmpfile" /etc/v2ray/config.json
            systemctl restart v2ray
            echo "✅ Utilisateur supprimé de V2Ray (VLESS TCP)"
        else
            echo "❌ Erreur JSON après suppression V2Ray"
            rm -f "$tmpfile"
        fi
    fi

    echo "✅ Utilisateur « $nom_supprime » supprimé complètement."
    read -p "Appuyez sur Entrée pour continuer..."
}

desinstaller_v2ray() {
    echo -n "Êtes-vous sûr de désinstaller uniquement V2Ray ? o/N : "
    read reponse
    if [[ "$reponse" =~ ^[Oo]$ ]]; then
        echo -e "${YELLOW}🛑 Arrêt du service V2Ray...${RESET}"

        # Stop et disable du service V2Ray
        systemctl stop v2ray.service 2>/dev/null || true
        systemctl disable v2ray.service 2>/dev/null || true
        rm -f /etc/systemd/system/v2ray.service 2>/dev/null

        # Supprimer les fichiers V2Ray
        rm -rf /etc/v2ray 2>/dev/null
        rm -f /usr/local/bin/v2ray 2>/dev/null
        rm -f /usr/local/bin/v2ctl 2>/dev/null
        rm -f /var/log/v2ray.log 2>/dev/null
        [ -f "$USER_DB" ] && rm -f "$USER_DB"

        # Nettoyer iptables V2Ray (port 5401 TCP)
        iptables -D INPUT -p tcp --dport 5401 -j ACCEPT 2>/dev/null || true
        netfilter-persistent save 2>/dev/null || true

        # Recharger systemd
        systemctl daemon-reload

        echo -e "${GREEN}✅ V2Ray désinstallé et nettoyé.${RESET}"
        echo -e "${CYAN}📊 Vérification ports :${RESET}"
        ss -tuln | grep -E "(:5401)" || echo "✅ Port 5401 libre"
    else
        echo "Annulé."
    fi
    read -p "Appuyez sur Entrée pour continuer..."
}

# Programme principal
while true; do
    afficher_menu
    afficher_mode_v2ray_ws
    show_menu
    read -p "Choisissez une option : " option

    SCRIPT_DIR="$HOME/Kighmu"  # Définition du chemin vers ton dossier Kighmu

    case "$option" in
        1)
            bash "$HOME/Kighmu/install_v2ray.sh"
            ;;
        2)
            creer_utilisateur
            ;;
        3)
            lister_utilisateurs
            ;;
        4)
            supprimer_utilisateur
            ;;
        5)
            desinstaller_v2ray
            ;;
        6)
            echo "📡 Ouverture du panneau de contrôle du bot Telegram..."
            
            # Vérifie que le script existe
            if [ ! -f "$SCRIPT_DIR/bot2_pannel.sh" ]; then
                echo "❌ Script bot2_pannel.sh introuvable dans $SCRIPT_DIR"
                read -p "Appuyez sur Entrée pour continuer..."
                continue
            fi

            # Vérifie que le script est exécutable
            if [ ! -x "$SCRIPT_DIR/bot2_pannel.sh" ]; then
                chmod +x "$SCRIPT_DIR/bot2_pannel.sh"
            fi

            # Lancer le panneau dans le terminal
            "$SCRIPT_DIR/bot2_pannel.sh"
            ;;
        7)
            echo "📡 Ouverture du panneau de contrôle du pannel web..."
            
            # Vérifie que le script existe
            if [ ! -f "$SCRIPT_DIR/install-1.sh" ]; then
                echo "❌ Script install-1.sh introuvable dans $SCRIPT_DIR"
                read -p "Appuyez sur Entrée pour continuer..."
                continue
            fi

            # Vérifie que le script est exécutable
            if [ ! -x "$SCRIPT_DIR/install-1.sh" ]; then
                chmod +x "$SCRIPT_DIR/install-1.sh"
            fi

            # Lancer le panneau dans le terminal
            "$SCRIPT_DIR/install-1.sh"
            ;;
        8)
            echo "📡 Ouverture du bot vless Gc web..."
            
            # Vérifie que le script existe
            if [ ! -f "$SCRIPT_DIR/kighmu-server.sh" ]; then
                echo "❌ Script kighmu-server.sh introuvable dans $SCRIPT_DIR"
                read -p "Appuyez sur Entrée pour continuer..."
                continue
            fi

            # Vérifie que le script est exécutable
            if [ ! -x "$SCRIPT_DIR/kighmu-server.sh" ]; then
                chmod +x "$SCRIPT_DIR/kighmu-server.sh"
            fi

            # Lancer le panneau dans le terminal
            "$SCRIPT_DIR/kighmu-server.sh"
            ;;
        0)
            echo "👋 Au revoir"
            exit 0
            ;;
        *)
            echo "❌ Option invalide."
            sleep 1
            ;;
    esac
done
