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
CONFIG_FILE="$SLOWDNS_DIR/nv4/ns.conf"
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
    local BLOCKED_DB="/etc/v2ray/blocked_users.json"  # ✅ AJOUTÉ

    [[ ! -f "$config" ]] && return 1

    local tmpfile
    tmpfile=$(mktemp)
    trap 'rm -f "$tmpfile"' EXIT INT TERM  # ✅ Nettoyage garanti

    jq --arg uuid "$uuid" '
    .inbounds |= map(
        if .protocol=="vless" or .protocol=="vmess" then
            .settings.clients |= map(select(.id != $uuid))
        else . end
    )' "$config" > "$tmpfile"

    if jq empty "$tmpfile" >/dev/null 2>&1; then
        mv "$tmpfile" "$config"
        systemctl restart v2ray

        # ✅ CORRIGÉ : BLOCKED_DB défini + initialisation si absent/corrompu
        local blocked
        blocked=$(cat "$BLOCKED_DB" 2>/dev/null || echo "[]")
        if ! echo "$blocked" | jq empty >/dev/null 2>&1; then
            blocked="[]"
        fi

        blocked=$(echo "$blocked" | jq \
            --arg u "$uuid" --arg n "$nom" \
            --arg r "$raison" --arg d "$(date +%Y-%m-%d)" \
            '. += [{"uuid": $u, "nom": $n, "raison": $r, "date": $d}]')

        # ✅ Écriture atomique
        local btmp
        btmp=$(mktemp)
        echo "$blocked" > "$btmp"
        if jq empty "$btmp" >/dev/null 2>&1; then
            mv "$btmp" "$BLOCKED_DB"
            chmod 600 "$BLOCKED_DB"
        else
            rm -f "$btmp"
        fi

        echo -e "${YELLOW}🔒 $nom bloqué ($raison)${RESET}"
    else
        rm -f "$tmpfile"
    fi

    trap - EXIT INT TERM
}

# ── Vérifier quotas et expirations (appelé par cron) ───────────
verifier_quotas() {
    charger_utilisateurs
    local today; today=$(date +%Y-%m-%d)
    local count; count=$(echo "$utilisateurs" | jq length)
    (( count == 0 )) && return

    # ✅ CORRIGÉ : parsing JSON natif au lieu du regex fragile
    declare -A used_bytes_map=()
    local api_json
    api_json=$("$V2RAY_BIN" api statsquery --server="$V2RAY_API" -reset 2>/dev/null) || true

    if echo "$api_json" | jq empty >/dev/null 2>&1; then
        while IFS=$'\t' read -r name value; do
            if [[ "$name" =~ user\>\>\>([^\>]+)\>\>\>traffic\>\>\> ]]; then
                local user="${BASH_REMATCH[1]}"
                local bytes="${value:-0}"
                used_bytes_map["$user"]=$(( ${used_bytes_map["$user"]:-0} + bytes ))
            fi
        done < <(echo "$api_json" | jq -r '.stat[]? | [.name, (.value // "0")] | @tsv' 2>/dev/null)
    else
        echo -e "${YELLOW}⚠️  API stats indisponible — quotas non vérifiés ce cycle${RESET}"
        return
    fi

    local changed=0
    for i in $(seq 0 $((count - 1))); do
        # ✅ CORRIGÉ : tous les champs en une seule invocation jq
        local fields
        fields=$(echo "$utilisateurs" | jq -r \
            ".[$i] | [.nom, .uuid, .expire, (.data_limit_gb // 0 | tostring), (.used_bytes // 0 | tostring)] | @tsv")
        IFS=$'\t' read -r nom uuid expire limit used <<< "$fields"

        local new_bytes="${used_bytes_map[$nom]:-0}"
        local total_used=$(( used + new_bytes ))

        utilisateurs=$(echo "$utilisateurs" | jq \
            --argjson i "$i" --argjson b "$total_used" \
            '.[$i].used_bytes = $b')
        changed=1

        # Vérifier expiration
        if [[ "$expire" < "$today" ]]; then
            bloquer_utilisateur "$uuid" "$nom" "expiration"
            continue
        fi

        # Vérifier quota (si limit > 0)
        if awk -v l="$limit" 'BEGIN {exit !(l > 0)}'; then
            local limit_bytes
            limit_bytes=$(awk -v l="$limit" 'BEGIN {printf "%d", l * 1073741824}')
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
    if systemctl is-active --quiet slowdns-ns4.service; then
        echo -e "${CYAN}Tunnel V2RAY DNS actif:${RESET}"
        echo -e "  - V2RAY DNS sur le port UDP ${GREEN}5401${RESET} → V2Ray 5401"
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
    
# ── Créer un utilisateur ───────────────────────────────────────
creer_utilisateur() {
    local nom duree data_limit uuid date_exp domaine

    echo -n "Entrez un nom d'utilisateur : "
    read -r nom

    # ✅ AJOUTÉ : validation nom
    if ! [[ "$nom" =~ ^[a-zA-Z0-9_-]{2,32}$ ]]; then
        echo -e "${RED}❌ Nom invalide (2-32 caractères, lettres/chiffres/-/_)${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    echo -n "Durée de validité (en jours) : "
    read -r duree
    if ! [[ "$duree" =~ ^[0-9]+$ ]] || (( duree < 1 )); then
        echo -e "${RED}❌ Durée invalide${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    echo -n "Limite de données en Go (ex: 10.50, 0 = illimité) : "
    read -r data_limit
    if ! [[ "$data_limit" =~ ^[0-9]+([.][0-9]{1,2})?$ ]]; then
        echo -e "${RED}❌ Limite invalide (ex: 10.50 ou 0)${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    if id "$nom" &>/dev/null; then
        echo -e "${RED}❌ L'utilisateur Linux existe déjà${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    charger_utilisateurs

    uuid=$(cat /proc/sys/kernel/random/uuid)
    date_exp=$(date -d "+${duree} days" +%Y-%m-%d)

    useradd -m -s /bin/bash "$nom" || {
        echo -e "${RED}❌ Erreur création utilisateur Linux${RESET}"
        read -p "Entrée pour continuer..."; return
    }
    echo "$nom:$uuid" | chpasswd
    chage -E "$date_exp" "$nom"

    # Ajouter dans la base JSON
    utilisateurs=$(echo "$utilisateurs" | jq \
        --arg n "$nom" --arg u "$uuid" --arg d "$date_exp" \
        --argjson l "${data_limit:-0}" \
        '. += [{"nom": $n, "uuid": $u, "expire": $d, "data_limit_gb": $l, "used_bytes": 0}]')
    sauvegarder_utilisateurs

    # ✅ CORRIGÉ : vérification V2Ray avant ajout
    if [[ ! -f /etc/v2ray/config.json ]]; then
        echo -e "${YELLOW}⚠️  V2Ray non installé — option 1 obligatoire${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    # ✅ CORRIGÉ : UN SEUL restart ici via ajouter_client_v2ray
    # Le bloc de nettoyage des expirés a été retiré — géré par le cron uniquement
    if ! ajouter_client_v2ray "$uuid" "$nom"; then
        echo -e "${RED}❌ Erreur ajout dans V2Ray${RESET}"
        read -p "Entrée pour continuer..."; return
    fi

    # Domaine
    if [[ -f /.v2ray_domain ]]; then
        domaine=$(cat /.v2ray_domain)
    else
        domaine="votre-domaine.com"
    fi

    local V2RAY_INTER_PORT="5401"
    local FASTDNS_PORT="${PORT:-5400}"
    local lien_vless="vless://${uuid}@${domaine}:${V2RAY_INTER_PORT}?type=tcp&encryption=none&host=${domaine}#${nom}-VLESS-TCP"

    SLOWDNS_DIR="/etc/slowdns"
    [[ -f "$SLOWDNS_DIR/slowdns.env" ]] && source "$SLOWDNS_DIR/slowdns.env"
    local PUB_KEY=${PUB_KEY:-$( [[ -f "$SLOWDNS_DIR/server.pub" ]] && cat "$SLOWDNS_DIR/server.pub" || echo "clé_non_disponible" )}
    local NAMESERVER=${NS:-$( [[ -f "$SLOWDNS_DIR/ns.conf" ]] && cat "$SLOWDNS_DIR/ns.conf" || echo "NS_non_defini" )}

    clear
    echo -e "${GREEN}============================================"
    echo -e "🧩 VLESS TCP + FASTDNS"
    echo -e "====================================================${RESET}"
    echo -e "📄 Configuration pour : ${YELLOW}$nom${RESET}"
    echo -e "-------------------------------------------------------------"
    echo -e "➤ DOMAINE : ${GREEN}$domaine${RESET}"
    echo -e "➤ PORTS :"
    echo -e "   FastDNS UDP : ${GREEN}$FASTDNS_PORT${RESET}"
    echo -e "   V2Ray TCP   : ${GREEN}$V2RAY_INTER_PORT${RESET}"
    echo -e "➤ UUID / Password : ${GREEN}$uuid${RESET}"
    echo -e "➤ Validité : ${YELLOW}$duree${RESET} jours (expire : $date_exp)"
    if [[ "$data_limit" == "0" ]]; then
        echo -e "➤ Quota : ${GREEN}Illimité${RESET}"
    else
        echo -e "➤ Quota : ${GREEN}${data_limit} Go${RESET}"
    fi
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━  CONFIGS SLOWDNS PORT 5400 ━━━━━━━━━━━━━●${RESET}"
    echo -e "${CYAN}Clé publique FastDNS :${RESET} $PUB_KEY"
    echo -e "${CYAN}NameServer :${RESET} $NAMESERVER"
    echo ""
    echo -e "${GREEN}●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●${RESET}"
    echo -e "${YELLOW}┃ Lien VLESS : $lien_vless${RESET}"
    echo -e "${GREEN}●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●${RESET}"
    echo ""
    read -p "Appuyez sur Entrée pour continuer..."
}

# ── Purger les utilisateurs expirés (cron uniquement) ──────────
# ✅ NOUVEAU : isolée de creer_utilisateur() pour éviter le double restart
purger_expires() {
    charger_utilisateurs
    local today; today=$(date +%Y-%m-%d)

    # Récupérer les UUIDs expirés
    local uuids_expire
    uuids_expire=$(echo "$utilisateurs" | jq -r \
        --arg today "$today" \
        '.[] | select(.expire < $today) | .uuid')

    # Rien à purger
    [[ -z "$uuids_expire" ]] && return 0

    local uuids_json
    uuids_json=$(echo "$uuids_expire" | jq -R -s -c 'split("\n")[:-1]')

    # Supprimer les UUIDs expirés de config.json
    if [[ -f /etc/v2ray/config.json ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        trap 'rm -f "$tmpfile"' EXIT INT TERM

        jq --argjson uuids "$uuids_json" '
        .inbounds |= map(
            if .protocol=="vless" then
                .settings.clients |= map(
                    select(.id as $id | $uuids | index($id) | not)
                )
            else . end
        )' /etc/v2ray/config.json > "$tmpfile"

        if jq empty "$tmpfile" >/dev/null 2>&1 && \
           /usr/local/bin/v2ray test -config "$tmpfile" >/dev/null 2>&1; then
            mv "$tmpfile" /etc/v2ray/config.json
            trap - EXIT INT TERM

            systemctl restart v2ray
            sleep 2
            if systemctl is-active --quiet v2ray; then
                echo "$(date) — expirés purgés : $uuids_expire" >> /var/log/v2ray_watchdog.log
            else
                echo "$(date) — ❌ V2Ray KO après purge" >> /var/log/v2ray_watchdog.log
                journalctl -u v2ray.service -n 10 --no-pager
                return 1
            fi
        else
            echo -e "${RED}❌ Config invalide — purge annulée${RESET}"
            rm -f "$tmpfile"
            trap - EXIT INT TERM
            return 1
        fi
    fi

    # Supprimer les expirés de utilisateurs.json
    utilisateurs=$(echo "$utilisateurs" | jq \
        --arg today "$today" \
        '[.[] | select(.expire >= $today)]')
    sauvegarder_utilisateurs

    echo -e "${GREEN}✅ Utilisateurs expirés purgés${RESET}"
}

# ── Supprimer un utilisateur ───────────────────────────────────
supprimer_utilisateur() {
    charger_utilisateurs
    local count; count=$(echo "$utilisateurs" | jq length)

    if (( count == 0 )); then
        echo "Aucun utilisateur à supprimer."
        read -p "Appuyez sur Entrée pour continuer..."; return
    fi

    echo "Utilisateurs actuels :"
    for i in $(seq 0 $((count - 1))); do
        # ✅ CORRIGÉ : un seul appel jq par ligne au lieu de 3
        local fields
        fields=$(echo "$utilisateurs" | jq -r ".[$i] | [.nom, .expire, .uuid] | @tsv")
        IFS=$'\t' read -r nom expire uuid <<< "$fields"
        echo "$((i+1))) $nom | expire le $expire | UUID: $uuid"
    done

    echo -n "Numéro à supprimer : "
    read -r choix

    # ✅ AJOUTÉ : validation stricte du choix
    if ! [[ "$choix" =~ ^[0-9]+$ ]] || (( choix < 1 || choix > count )); then
        echo "Choix invalide."
        read -p "Appuyez sur Entrée pour continuer..."; return
    fi

    local index=$(( choix - 1 ))
    local fields
    fields=$(echo "$utilisateurs" | jq -r ".[$index] | [.nom, .uuid] | @tsv")
    IFS=$'\t' read -r nom_supprime uuid_supprime <<< "$fields"

    # Supprimer de la base JSON
    utilisateurs=$(echo "$utilisateurs" | jq "del(.[$index])")
    sauvegarder_utilisateurs || return 1

    # ✅ CORRIGÉ : validation JSON complète avant/après via tmpfile
    if [[ -f /etc/v2ray/config.json ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        trap 'rm -f "$tmpfile"' EXIT INT TERM

        jq --arg uuid "$uuid_supprime" '
        .inbounds |= map(
            if .protocol=="vless" or .protocol=="vmess" then
                .settings.clients |= map(select(.id != $uuid))
            else . end
        )' /etc/v2ray/config.json > "$tmpfile"

        if jq empty "$tmpfile" >/dev/null 2>&1 && \
           /usr/local/bin/v2ray test -config "$tmpfile" >/dev/null 2>&1; then
            mv "$tmpfile" /etc/v2ray/config.json
            trap - EXIT INT TERM

            # ✅ CORRIGÉ : restart avec vérification
            systemctl restart v2ray
            sleep 2
            if systemctl is-active --quiet v2ray; then
                echo -e "${GREEN}✅ Utilisateur supprimé de V2Ray${RESET}"
            else
                echo -e "${RED}❌ V2Ray n'a pas redémarré après suppression${RESET}"
                journalctl -u v2ray.service -n 10 --no-pager
            fi
        else
            echo -e "${RED}❌ JSON ou config invalide — suppression V2Ray annulée${RESET}"
            rm -f "$tmpfile"
            trap - EXIT INT TERM
        fi
    fi

    # ✅ AJOUTÉ : suppression utilisateur Linux
    if id "$nom_supprime" &>/dev/null; then
        userdel -r "$nom_supprime" 2>/dev/null \
            && echo -e "${GREEN}✅ Utilisateur Linux supprimé${RESET}" \
            || echo -e "${YELLOW}⚠️  Impossible de supprimer l'utilisateur Linux${RESET}"
    fi

    echo -e "${GREEN}✅ Utilisateur « $nom_supprime » supprimé complètement.${RESET}"
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
