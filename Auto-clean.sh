#!/bin/bash
# ==========================================
# Auto-clean + collecte trafic + quota data
# V2Ray, ZIVPN, Xray, Hysteria & SSH
# ==========================================
set -euo pipefail

LOG_FILE="/var/log/auto-clean.log"
TODAY=$(date +%Y-%m-%d)
TS() { date '+%Y-%m-%d %H:%M:%S'; }

# ── Config panel (lu depuis .env) ────────────────────────────
PANEL_ENV="/opt/kighmu-panel/.env"
PANEL_URL="http://127.0.0.1:3000"
REPORT_SECRET="kighmu-report-2024"
if [[ -f "$PANEL_ENV" ]]; then
    _p=$(grep '^PORT='           "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    _s=$(grep '^REPORT_SECRET=' "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    [[ -n "$_p" ]] && PANEL_URL="http://127.0.0.1:${_p}"
    [[ -n "$_s" ]] && REPORT_SECRET="$_s"
fi

# Si REPORT_SECRET toujours vide, lire depuis traffic-collect.sh
if [[ "$REPORT_SECRET" == "kighmu-report-2024" ]]; then
    _tc="/etc/kighmu/traffic-collect.sh"
    if [[ -f "$_tc" ]]; then
        _s2=$(grep '^SECRET=' "$_tc" 2>/dev/null | cut -d'"' -f2 || true)
        [[ -n "$_s2" ]] && REPORT_SECRET="$_s2"
    fi
fi

# ── Config MySQL (lu depuis .env) ────────────────────────────
DB_HOST="127.0.0.1"; DB_PORT="3306"; DB_NAME="kighmu_panel"
DB_USER_CONF=""; DB_PASS_CONF=""
if [[ -f "$PANEL_ENV" ]]; then
    DB_HOST=$(grep '^DB_HOST='     "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "127.0.0.1")
    DB_PORT=$(grep '^DB_PORT='     "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "3306")
    DB_NAME=$(grep '^DB_NAME='     "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "kighmu_panel")
    DB_USER_CONF=$(grep '^DB_USER='     "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
    DB_PASS_CONF=$(grep '^DB_PASSWORD=' "$PANEL_ENV" 2>/dev/null | cut -d= -f2 | tr -d '"' || true)
fi

MYSQL_OK=0
if command -v mysql &>/dev/null && [[ -n "$DB_USER_CONF" ]]; then
    if mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER_CONF" -p"$DB_PASS_CONF" \
        -e "USE ${DB_NAME};" 2>/dev/null; then
        MYSQL_OK=1
    fi
fi
mysql_query() {
    mysql -h"$DB_HOST" -P"$DB_PORT" -u"$DB_USER_CONF" -p"$DB_PASS_CONF" \
        -N -s "$DB_NAME" -e "$1" 2>/dev/null
}

echo "[$(TS)] ============================================" >> "$LOG_FILE"
echo "[$(TS)] Debut nettoyage + collecte trafic + quota"   >> "$LOG_FILE"

# ── Déduplication v2ray config.json ─────────────────────────
dedup_v2ray() {
    local cfg="${V2RAY_CONFIG:-/etc/v2ray/config.json}"
    [[ ! -f "$cfg" ]] && return
    local tmp; tmp=$(mktemp)
    local before after
    before=$(jq '[.inbounds[] | select(.protocol=="vless" or .protocol=="vmess") | .settings.clients // [] | length] | add // 0' "$cfg" 2>/dev/null)
    jq '
    .inbounds |= map(
        if (.protocol=="vless" or .protocol=="vmess") and .settings.clients then
            .settings.clients |= (
                reduce .[] as $c (
                    {"seen_ids": [], "seen_emails": [], "result": []};
                    if (.seen_ids | index($c.id)) != null or
                       ($c.email != null and (.seen_emails | index($c.email)) != null)
                    then .
                    else
                        .seen_ids += [$c.id] |
                        .seen_emails += (if $c.email then [$c.email] else [] end) |
                        .result += [$c]
                    end
                ) | .result
            )
        else . end
    )' "$cfg" > "$tmp" 2>/dev/null
    if jq empty "$tmp" >/dev/null 2>&1; then
        after=$(jq '[.inbounds[] | select(.protocol=="vless" or .protocol=="vmess") | .settings.clients // [] | length] | add // 0' "$tmp" 2>/dev/null)
        mv "$tmp" "$cfg"
        if (( before > after )); then
            echo "[$(TS)] [DEDUP-V2RAY] $((before - after)) doublon(s) supprimé(s) ($before → $after)" >> "$LOG_FILE"
            systemctl restart v2ray 2>/dev/null || true
        fi
    else
        rm -f "$tmp"
    fi
}
dedup_v2ray

# ============================================================
# VARIABLES GLOBALES SSH
# ============================================================
BW_DIR="/var/lib/kighmu/bandwidth"
USER_FILE="/etc/kighmu/users.list"
mkdir -p "$BW_DIR"

# ==========================================
# SECTION 0 : Collecte trafic -> panel
# ==========================================

send_stats() {
    local json="$1"
    local resp
    resp=$(curl -s --max-time 10 -X POST "${PANEL_URL}/api/report/traffic" \
        -H "Content-Type: application/json" \
        -H "x-report-secret: ${REPORT_SECRET}" \
        -d "${json}" 2>/dev/null) || true
    echo "[$(TS)] [TRAFFIC] -> ${resp:-pas de reponse}" >> "$LOG_FILE"
}

# ── 0a. Xray — commande : xray api statsquery ────────────────
# Format de sortie Xray 26.x : JSON
# {
#   "stat": [
#     { "name": "user>>>kighmu49>>>traffic>>>uplink", "value": "12345" },
#     { "name": "user>>>kighmu49>>>traffic>>>downlink", "value": "67890" }
#   ]
# }
# NOTE : les clients sans email ou avec email "default" ne génèrent
# pas de stats par user — il faut que chaque client ait un email = username.
collect_xray_traffic() {
    local bin="${XRAY_BIN:-/usr/local/bin/xray}"
    local api="${XRAY_API:-127.0.0.1:10085}"
    [[ ! -x "$bin" ]] && return
    command -v jq &>/dev/null || {
        echo "[$(TS)] [XRAY] jq absent — impossible de parser les stats" >> "$LOG_FILE"
        return
    }

    local raw
    # --reset : remet les compteurs à 0 après lecture (évite le double-comptage)
    raw=$("$bin" api statsquery --server="$api" --reset 2>/dev/null) || return
    [[ -z "$raw" ]] && { echo "[$(TS)] [XRAY] Aucune stat" >> "$LOG_FILE"; return; }

    # Parser le JSON avec jq : extraire uniquement les stats "user>>>"
    # Ignorer "default" (client pré-installé sans username réel)
    declare -A up_map=()
    declare -A down_map=()

    while IFS='|' read -r name value; do
        [[ -z "$name" ]] && continue  # ne pas skipper value=0
        # Format name: "user>>>TAG>>>traffic>>>uplink"
        if [[ "$name" =~ ^user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link$ ]]; then
            local tag="${BASH_REMATCH[1]}" dir="${BASH_REMATCH[2]}"
            [[ "$tag" == "default" ]] && continue
            # Extraire le username depuis le tag (format: proto_username_uuid8)
            # ex: vless_89uuo_da5bae66 → 89uuo
            local user
            if [[ "$tag" =~ ^[a-z]+_(.+)_[0-9a-f]{8}$ ]]; then
                user="${BASH_REMATCH[1]}"
            else
                user="$tag"  # fallback: utiliser le tag complet
            fi
            local val="${value:-0}"
            [[ "$dir" == "up"   ]] && up_map["$user"]=$(( ${up_map["$user"]:-0}   + val ))
            [[ "$dir" == "down" ]] && down_map["$user"]=$(( ${down_map["$user"]:-0} + val ))
        fi
    done < <(echo "$raw" | jq -r '.stat[]? | select(.name != null) | "\(.name)|\(.value // "0")"' 2>/dev/null)

    local json='{"stats":[' first=1
    for user in $(echo "${!up_map[@]} ${!down_map[@]}" | tr ' ' '\n' | sort -u); do
        local up="${up_map[$user]:-0}" dn="${down_map[$user]:-0}"
        (( up + dn == 0 )) && continue
        [[ $first -eq 0 ]] && json+=","
        json+="{\"username\":\"$user\",\"upload_bytes\":$up,\"download_bytes\":$dn}"
        first=0
    done
    json+="]}"

    if [[ $first -eq 0 ]]; then
        echo "[$(TS)] [XRAY] Envoi stats..." >> "$LOG_FILE"
        send_stats "$json"
    else
        echo "[$(TS)] [XRAY] Aucun trafic user (vérifiez que les clients ont un email=username)" >> "$LOG_FILE"
    fi
}

# ── 0b. V2Ray — commande : v2ray api stats ───────────────────
# Format de sortie V2Ray 5.x (tableau texte) :
#   IDX   SIZE    NAME
#   3   262.93KB  inbound>>>ssh>>>traffic>>>downlink
#   4   108.65KB  inbound>>>ssh>>>traffic>>>uplink
#
# Le trafic SSH passe entièrement par V2Ray (dokodemo-door port 5401→22).
# Comme V2Ray ne connaît pas les usernames SSH individuels (dokodemo-door
# ne fait pas d'authentification), on répartit le trafic de l'inbound "ssh"
# équitablement entre tous les users SSH actifs connectés via ce tunnel.
# Pour vless-fastdns, les stats sont par user (email dans les clients).
collect_v2ray_traffic() {
    local bin="${V2RAY_BIN:-/usr/local/bin/v2ray}"
    local api="${V2RAY_API:-127.0.0.1:10086}"
    [[ ! -x "$bin" ]] && return
    # Vérifier que l'API répond
    ss -tnlp 2>/dev/null | grep -q "${api##*:}" || {
        echo "[$(TS)] [V2RAY] API non disponible sur $api" >> "$LOG_FILE"
        return
    }

    local raw
    # -reset : remet les compteurs à 0 après lecture
    raw=$("$bin" api stats --server="$api" -reset 2>/dev/null) || return
    [[ -z "$raw" ]] && { echo "[$(TS)] [V2RAY] Aucune stat" >> "$LOG_FILE"; return; }

    # Parser le format texte : "IDX  SIZE  NAME"
    # Convertir les tailles en bytes (B, KB, MB, GB)
    to_bytes() {
        local val="$1"
        # Format: "262.93KB" ou "108.65KB" ou "54.00B" ou "1.23MB"
        if [[ "$val" =~ ^([0-9]+\.?[0-9]*)([KMGT]?B)$ ]]; then
            local num="${BASH_REMATCH[1]}" unit="${BASH_REMATCH[2]}"
            case "$unit" in
                B)  awk "BEGIN {printf \"%d\", $num}" ;;
                KB) awk "BEGIN {printf \"%d\", $num * 1024}" ;;
                MB) awk "BEGIN {printf \"%d\", $num * 1048576}" ;;
                GB) awk "BEGIN {printf \"%d\", $num * 1073741824}" ;;
                *)  echo "0" ;;
            esac
        else
            echo "0"
        fi
    }

    # Accumuler trafic SSH inbound (tous users confondus)
    local ssh_down=0 ssh_up=0
    # Accumuler trafic vless par user (email)
    declare -A up_map=()
    declare -A down_map=()

    while IFS= read -r line; do
        # Format: "  3   262.93KB    inbound>>>ssh>>>traffic>>>downlink"
        if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]+([0-9]+\.?[0-9]*[KMGT]?B)[[:space:]]+(.*) ]]; then
            local size_str="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
            local bytes; bytes=$(to_bytes "$size_str")

            # SSH inbound (dokodemo-door)
            if [[ "$name" == "inbound>>>ssh>>>traffic>>>downlink" ]]; then
                ssh_down=$bytes
            elif [[ "$name" == "inbound>>>ssh>>>traffic>>>uplink" ]]; then
                ssh_up=$bytes
            # Vless par user : "user>>>USERNAME>>>traffic>>>uplink"
            elif [[ "$name" =~ user\>\>\>([^\>]+)\>\>\>traffic\>\>\>(up|down)link ]]; then
                local user="${BASH_REMATCH[1]}" dir="${BASH_REMATCH[2]}"
                [[ "$dir" == "up"   ]] && up_map["$user"]=$(( ${up_map["$user"]:-0}   + bytes ))
                [[ "$dir" == "down" ]] && down_map["$user"]=$(( ${down_map["$user"]:-0} + bytes ))
            fi
        fi
    done <<< "$raw"

    local json='{"stats":[' first=1

    # Trafic SSH inbound (dokodemo-door 127.0.0.1→port 22)
    # Méthode : auth.log donne PID→username pour chaque "Accepted password from 127.0.0.1"
    # Les PIDs actifs dans ss sont les enfants (PPid) des PIDs auth.log
    if (( ssh_up + ssh_down > 0 )); then
        declare -A sess_count=()

        # Construire map pid_parent→username depuis auth.log (dernières 24h)
        declare -A pid_user_map=()
        while IFS= read -r line; do
            # Format: "... sshd[PID]: Accepted password for USERNAME from 127.0.0.1 ..."
            if [[ "$line" =~ sshd\[([0-9]+)\]:.*Accepted\ password\ for\ ([^[:space:]]+)\ from\ 127\.0\.0\.1 ]]; then
                local apid="${BASH_REMATCH[1]}" auser="${BASH_REMATCH[2]}"
                [[ "$auser" == "root" ]] && continue
                # Vérifier que c'est un user VPN connu
                [[ -f "$USER_FILE" ]] && \
                    grep -q "^${auser}|" "$USER_FILE" 2>/dev/null || continue
                pid_user_map["$apid"]="$auser"
            fi
        done < <(grep "Accepted password" /var/log/auth.log 2>/dev/null | grep "127.0.0.1" | tail -500)

        # Pour chaque connexion SSH active, remonter au PID auth.log via PPid
        while IFS= read -r line; do
            # ss output: "... users:(("sshd",pid=XXXX,fd=Y),("sshd",pid=YYYY,fd=Z))"
            while [[ "$line" =~ pid=([0-9]+) ]]; do
                local cpid="${BASH_REMATCH[1]}"
                line="${line#*pid=${cpid}}"
                # Lire le PPid de ce processus
                local ppid
                ppid=$(awk '/^PPid:/{print $2}' "/proc/$cpid/status" 2>/dev/null)
                [[ -z "$ppid" ]] && continue
                # Chercher le username dans la map (pid direct ou parent)
                local found_user=""
                [[ -n "${pid_user_map[$cpid]:-}" ]] && found_user="${pid_user_map[$cpid]}"
                [[ -z "$found_user" && -n "${pid_user_map[$ppid]:-}" ]] && found_user="${pid_user_map[$ppid]}"
                [[ -z "$found_user" ]] && continue
                sess_count["$found_user"]=$(( ${sess_count["$found_user"]:-0} + 1 ))
            done
        done < <(ss -tnp state established 2>/dev/null | grep ":22 ")

        # Dédupliquer : compter 1 session par PID parent unique par user
        # (ss liste 2 PIDs par connexion : parent+enfant)
        declare -A seen_pairs=()
        declare -A sess_dedup=()
        while IFS= read -r line; do
            local pids=()
            local tmp="$line"
            while [[ "$tmp" =~ pid=([0-9]+) ]]; do
                pids+=("${BASH_REMATCH[1]}")
                tmp="${tmp#*pid=${BASH_REMATCH[1]}}"
            done
            # Trouver le user associé à cette connexion
            local conn_user=""
            for p in "${pids[@]}"; do
                local pp; pp=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
                [[ -n "${pid_user_map[$p]:-}" ]]  && { conn_user="${pid_user_map[$p]}";  break; }
                [[ -n "${pid_user_map[$pp]:-}" ]] && { conn_user="${pid_user_map[$pp]}"; break; }
            done
            [[ -z "$conn_user" ]] && continue
            # Clé unique = PIDs triés pour éviter le double comptage
            local key; key=$(printf '%s\n' "${pids[@]}" | sort | tr '\n' '_')
            [[ -n "${seen_pairs[$key]:-}" ]] && continue
            seen_pairs["$key"]=1
            sess_dedup["$conn_user"]=$(( ${sess_dedup["$conn_user"]:-0} + 1 ))
        done < <(ss -tnp state established 2>/dev/null | grep ":22 ")

        local total_sess=0
        for u in "${!sess_dedup[@]}"; do
            total_sess=$(( total_sess + sess_dedup[$u] ))
        done

        if (( total_sess > 0 )); then
            echo "[$(TS)] [V2RAY] SSH inbound ↑${ssh_up}B ↓${ssh_down}B → réparti par sessions (total=${total_sess})" >> "$LOG_FILE"
            for uname in "${!sess_dedup[@]}"; do
                local weight="${sess_dedup[$uname]}"
                local u_up=$(( ssh_up   * weight / total_sess ))
                local u_dn=$(( ssh_down * weight / total_sess ))
                (( u_up + u_dn == 0 )) && continue
                [[ $first -eq 0 ]] && json+=","
                json+="{\"username\":\"${uname}\",\"upload_bytes\":${u_up},\"download_bytes\":${u_dn}}"
                echo "[$(TS)] [V2RAY]   $uname : ${weight} session(s) → ↑${u_up}B ↓${u_dn}B" >> "$LOG_FILE"
                first=0
            done
        else
            # Fallback : répartition égale sur tous les users connus
            local ssh_users=()
            while IFS='|' read -r username _rest; do
                [[ -z "$username" ]] && continue
                id "$username" &>/dev/null && ssh_users+=("$username")
            done < "$USER_FILE"
            local nb_users=${#ssh_users[@]}
            if (( nb_users > 0 )); then
                local share_up=$(( ssh_up   / nb_users ))
                local share_dn=$(( ssh_down / nb_users ))
                echo "[$(TS)] [V2RAY] SSH inbound — aucune session identifiée, répartition égale sur $nb_users user(s)" >> "$LOG_FILE"
                for uname in "${ssh_users[@]}"; do
                    [[ $first -eq 0 ]] && json+=","
                    json+="{\"username\":\"${uname}\",\"upload_bytes\":${share_up},\"download_bytes\":${share_dn}}"
                    first=0
                done
            fi
        fi
    fi

    # Trafic vless par user
    for user in $(echo "${!up_map[@]} ${!down_map[@]}" | tr ' ' '\n' | sort -u); do
        local up="${up_map[$user]:-0}" dn="${down_map[$user]:-0}"
        (( up + dn == 0 )) && continue
        [[ $first -eq 0 ]] && json+=","
        json+="{\"username\":\"$user\",\"upload_bytes\":$up,\"download_bytes\":$dn}"
        first=0
    done
    json+="]}"

    if [[ $first -eq 0 ]]; then
        echo "[$(TS)] [V2RAY] Envoi stats..." >> "$LOG_FILE"
        send_stats "$json"
    else
        echo "[$(TS)] [V2RAY] Aucun trafic" >> "$LOG_FILE"
    fi
}

# ── 0c. SSH : lecture des cumuls depuis le service kighmu-bandwidth ─────────
# Le service kighmu-bandwidth.sh accumule en temps réel dans BW_DIR/username.usage
# auto-clean.sh lit uniquement le delta depuis le dernier envoi et l'envoie au panel
collect_ssh_traffic() {
    local USER_FILE="/etc/kighmu/users.list"
    local BW_DIR="/var/lib/kighmu/bandwidth"
    local SENT_DIR="$BW_DIR/sent"
    [[ ! -f "$USER_FILE" ]] && return
    mkdir -p "$SENT_DIR"

    local json='{"stats":[' first=1 has_data=0

    while IFS='|' read -r username _rest; do
        [[ -z "$username" ]] && continue

        local usagefile="$BW_DIR/${username}.usage"
        [[ ! -f "$usagefile" ]] && continue

        local accumulated
        accumulated=$(cat "$usagefile" 2>/dev/null)
        [[ ! "$accumulated" =~ ^[0-9]+$ ]] && continue
        (( accumulated == 0 )) && continue

        # Lire la dernière valeur envoyée au panel
        local sentfile="$SENT_DIR/${username}.sent"
        local last_sent=0
        [[ -f "$sentfile" ]] && last_sent=$(cat "$sentfile" 2>/dev/null)
        [[ ! "$last_sent" =~ ^[0-9]+$ ]] && last_sent=0

        # Delta depuis le dernier envoi
        local delta=$(( accumulated - last_sent ))
        (( delta <= 0 )) && continue

        # Sauvegarder la valeur envoyée
        echo "$accumulated" > "$sentfile"

        local half=$(( delta / 2 ))
        local other=$(( delta - half ))

        [[ $first -eq 0 ]] && json+=","
        json+="{\"username\":\"${username}\",\"upload_bytes\":${half},\"download_bytes\":${other}}"
        first=0
        has_data=1
        echo "[$(TS)] [SSH] $username +$(( delta / 1048576 ))MB (cumul: $(( accumulated / 1048576 ))MB)" >> "$LOG_FILE"
    done < "$USER_FILE"

    json+="]}"
    if [[ $has_data -eq 1 ]]; then
        echo "[$(TS)] [SSH] Envoi stats..." >> "$LOG_FILE"
        send_stats "$json"
    else
        echo "[$(TS)] [SSH] Aucun nouveau trafic SSH" >> "$LOG_FILE"
    fi
}

# ── 0d. UDP Zivpn + Hysteria : mesure trafic via iptables par port ───────────
# Principe :
#   - Créer une règle iptables de comptage par port (une règle globale par proto)
#   - Lire le delta de bytes depuis la dernière lecture
#   - Distribuer équitablement entre les users actifs connectés à ce moment
#   - Envoyer au panel via /api/report/traffic
#
# Ports : Zivpn    = lu depuis /etc/zivpn/config.json (defaut: 5667 UDP)
#          Hysteria = 20000:50000 (UDP)
# ─────────────────────────────────────────────────────────────────────────────

# Initialiser les règles iptables de comptage UDP (appelé une seule fois)
# NE PAS vider les compteurs si la chaîne existe déjà — sinon on perd le trafic !
init_udp_iptables() {
    # Si la chaîne existe déjà avec ses règles, ne rien toucher (préserver les compteurs)
    if iptables -L KIGHMU_UDP_COUNT &>/dev/null 2>&1; then
        local nb_rules
        nb_rules=$(iptables -nvx -L KIGHMU_UDP_COUNT 2>/dev/null | grep -cE "udp (dpt|spt)" || true)
        if (( nb_rules >= 4 )); then
            # Chaîne déjà initialisée — ne pas flush, juste vérifier qu'elle est bien hookée
            iptables -C INPUT  -j KIGHMU_UDP_COUNT 2>/dev/null || iptables -I INPUT  1 -j KIGHMU_UDP_COUNT 2>/dev/null || true
            iptables -C OUTPUT -j KIGHMU_UDP_COUNT 2>/dev/null || iptables -I OUTPUT 1 -j KIGHMU_UDP_COUNT 2>/dev/null || true
            return
        fi
    fi

    # Première initialisation : créer la chaîne et les règles
    iptables -N KIGHMU_UDP_COUNT 2>/dev/null || true
    iptables -F KIGHMU_UDP_COUNT 2>/dev/null || true

    # Lire le port ZIVPN dynamiquement depuis config.json (defaut: 5667)
    local zivpn_port="5667"
    if [[ -f /etc/zivpn/config.json ]]; then
        local _zp; _zp=$(python3 -c "import json; d=json.load(open('/etc/zivpn/config.json')); print(d.get('listen',':5667').lstrip(':'))" 2>/dev/null)
        [[ "$_zp" =~ ^[0-9]+$ ]] && zivpn_port="$_zp"
    fi
    echo "[$(TS)] [UDP] Port ZIVPN detecte : ${zivpn_port}" >> "$LOG_FILE"
    # Comptage brut sans condition mark (intercepte tout le trafic UDP)
    iptables -A KIGHMU_UDP_COUNT -p udp --dport ${zivpn_port}  2>/dev/null || true
    iptables -A KIGHMU_UDP_COUNT -p udp --sport ${zivpn_port}  2>/dev/null || true
    iptables -A KIGHMU_UDP_COUNT -p udp --dport 20000:50000 2>/dev/null || true
    iptables -A KIGHMU_UDP_COUNT -p udp --sport 20000:50000 2>/dev/null || true

    # Insérer en position 1 dans INPUT et OUTPUT AVANT les règles MARK
    iptables -D INPUT  -j KIGHMU_UDP_COUNT 2>/dev/null || true
    iptables -D OUTPUT -j KIGHMU_UDP_COUNT 2>/dev/null || true
    iptables -I INPUT  1 -j KIGHMU_UDP_COUNT 2>/dev/null || true
    iptables -I OUTPUT 1 -j KIGHMU_UDP_COUNT 2>/dev/null || true
    echo "[$(TS)] [UDP] Chaîne KIGHMU_UDP_COUNT initialisée" >> "$LOG_FILE"
}

# Upload = dport (paquet entrant vers serveur = client envoie)
read_udp_upload_bytes() {
    local port="$1" total=0
    while IFS= read -r bytes; do
        [[ "$bytes" =~ ^[0-9]+$ ]] && total=$(( total + bytes ))
    done < <(iptables -nvx -L KIGHMU_UDP_COUNT 2>/dev/null | grep -E "dpts?:${port}( |$)" | awk '{print $2}')
    echo "$total"
}

# Download = sport (paquet sortant du serveur vers client = client reçoit)
read_udp_download_bytes() {
    local port="$1" total=0
    while IFS= read -r bytes; do
        [[ "$bytes" =~ ^[0-9]+$ ]] && total=$(( total + bytes ))
    done < <(iptables -nvx -L KIGHMU_UDP_COUNT 2>/dev/null | grep -E "spts?:${port}( |$)" | awk '{print $2}')
    echo "$total"
}

read_udp_bytes_iptables() {
    local port="$1"
    echo $(( $(read_udp_upload_bytes "$port") + $(read_udp_download_bytes "$port") ))
}

collect_udp_traffic() {
    local BW_DIR="/var/lib/kighmu/bandwidth"
    local SENT_DIR="$BW_DIR/sent"
    mkdir -p "$BW_DIR" "$SENT_DIR"

    # Initialiser les règles iptables si nécessaire
    init_udp_iptables

    local json='{"stats":[' first=1 has_data=0
    local today
    today=$(date +%F)

    # ── Traiter Zivpn ────────────────────────────────────────────────────────
    local zivpn_uf="/etc/zivpn/users.list"
    if [[ -f "$zivpn_uf" ]]; then
        # Lire upload (dport=entrant) et download (sport=sortant) séparément
        local cur_zivpn_up cur_zivpn_dn
        cur_zivpn_up=$(read_udp_upload_bytes "5667")
        cur_zivpn_dn=$(read_udp_download_bytes "5667")
        [[ ! "$cur_zivpn_up" =~ ^[0-9]+$ ]] && cur_zivpn_up=0
        [[ ! "$cur_zivpn_dn" =~ ^[0-9]+$ ]] && cur_zivpn_dn=0
        local cur_zivpn=$(( cur_zivpn_up + cur_zivpn_dn ))

        local snap_zivpn_up="$BW_DIR/udp_zivpn_global_up.snap"
        local snap_zivpn_dn="$BW_DIR/udp_zivpn_global_dn.snap"
        local prev_zivpn_up=0 prev_zivpn_dn=0
        [[ -f "$snap_zivpn_up" ]] && prev_zivpn_up=$(cat "$snap_zivpn_up" 2>/dev/null)
        [[ -f "$snap_zivpn_dn" ]] && prev_zivpn_dn=$(cat "$snap_zivpn_dn" 2>/dev/null)
        [[ ! "$prev_zivpn_up" =~ ^[0-9]+$ ]] && prev_zivpn_up=0
        [[ ! "$prev_zivpn_dn" =~ ^[0-9]+$ ]] && prev_zivpn_dn=0

        local delta_zivpn_up delta_zivpn_dn
        (( cur_zivpn_up >= prev_zivpn_up )) && delta_zivpn_up=$(( cur_zivpn_up - prev_zivpn_up )) || delta_zivpn_up=$cur_zivpn_up
        (( cur_zivpn_dn >= prev_zivpn_dn )) && delta_zivpn_dn=$(( cur_zivpn_dn - prev_zivpn_dn )) || delta_zivpn_dn=$cur_zivpn_dn
        local delta_zivpn=$(( delta_zivpn_up + delta_zivpn_dn ))

        # RATTRAPAGE AUTOMATIQUE
        local recovery_zivpn=0
        if (( cur_zivpn > 0 )); then
            local total_sent_zivpn=0
            for sf in "$SENT_DIR"/udp_zivpn_*.sent; do
                [[ -f "$sf" ]] || continue
                local sv; sv=$(cat "$sf" 2>/dev/null)
                [[ "$sv" =~ ^[0-9]+$ ]] && total_sent_zivpn=$(( total_sent_zivpn + sv ))
            done
            local gap_zivpn=$(( cur_zivpn - total_sent_zivpn ))
            if (( gap_zivpn > 10485760 )); then
                recovery_zivpn=$gap_zivpn
                echo "[$(TS)] [UDP-zivpn] RATTRAPAGE : gap=$(( gap_zivpn / 1048576 ))MB" >> "$LOG_FILE"
            fi
        fi

        echo "$cur_zivpn_up" > "$snap_zivpn_up"
        echo "$cur_zivpn_dn" > "$snap_zivpn_dn"
        local effective_zivpn_up=$(( delta_zivpn_up + recovery_zivpn ))
        local effective_zivpn_dn=$delta_zivpn_dn
        local effective_zivpn=$(( effective_zivpn_up + effective_zivpn_dn ))
        echo "[$(TS)] [UDP-zivpn] up=$cur_zivpn_up dn=$cur_zivpn_dn delta_up=$delta_zivpn_up delta_dn=$delta_zivpn_dn" >> "$LOG_FILE"

        if (( effective_zivpn > 0 )); then
            local active_users=()
            while IFS='|' read -r username _pass expire; do
                [[ -z "$username" ]] && continue
                [[ "$expire" < "$today" ]] && continue
                active_users+=("$username")
            done < "$zivpn_uf"

            local nb=${#active_users[@]}
            if (( nb > 0 )); then
                local share_up=$(( effective_zivpn_up / nb ))
                local share_dn=$(( effective_zivpn_dn / nb ))
                local share=$(( share_up + share_dn ))

                for username in "${active_users[@]}"; do
                    local usagefile="$BW_DIR/udp_zivpn_${username}.usage"
                    local accum=0
                    [[ -f "$usagefile" ]] && accum=$(cat "$usagefile" 2>/dev/null)
                    [[ ! "$accum" =~ ^[0-9]+$ ]] && accum=0
                    accum=$(( accum + share ))
                    echo "$accum" > "$usagefile"

                    local sentfile="$SENT_DIR/udp_zivpn_${username}.sent"
                    local last_sent=0
                    [[ -f "$sentfile" ]] && last_sent=$(cat "$sentfile" 2>/dev/null)
                    [[ ! "$last_sent" =~ ^[0-9]+$ ]] && last_sent=0
                    local user_delta=$(( accum - last_sent ))
                    (( user_delta <= 0 )) && continue

                    echo "$accum" > "$sentfile"
                    [[ $first -eq 0 ]] && json+=","
                    json+="{\"username\":\"${username}\",\"upload_bytes\":${share_up},\"download_bytes\":${share_dn}}"
                    first=0; has_data=1
                    echo "[$(TS)] [UDP-zivpn] $username +$(( user_delta / 1048576 ))MB (total: $(( accum / 1048576 ))MB)" >> "$LOG_FILE"
                done
            fi
        fi
    fi

    # ── Traiter Hysteria ─────────────────────────────────────────────────────
    local hy_uf="/etc/hysteria/users.txt"
    if [[ -f "$hy_uf" ]]; then
        # Lire upload (dport=entrant) et download (sport=sortant) séparément
        local cur_hy_up cur_hy_dn
        cur_hy_up=$(read_udp_upload_bytes "20000:50000")
        cur_hy_dn=$(read_udp_download_bytes "20000:50000")
        [[ ! "$cur_hy_up" =~ ^[0-9]+$ ]] && cur_hy_up=0
        [[ ! "$cur_hy_dn" =~ ^[0-9]+$ ]] && cur_hy_dn=0
        local cur_hy=$(( cur_hy_up + cur_hy_dn ))

        local snap_hy_up="$BW_DIR/udp_hysteria_global_up.snap"
        local snap_hy_dn="$BW_DIR/udp_hysteria_global_dn.snap"
        local prev_hy_up=0 prev_hy_dn=0
        [[ -f "$snap_hy_up" ]] && prev_hy_up=$(cat "$snap_hy_up" 2>/dev/null)
        [[ -f "$snap_hy_dn" ]] && prev_hy_dn=$(cat "$snap_hy_dn" 2>/dev/null)
        [[ ! "$prev_hy_up" =~ ^[0-9]+$ ]] && prev_hy_up=0
        [[ ! "$prev_hy_dn" =~ ^[0-9]+$ ]] && prev_hy_dn=0

        local delta_hy_up delta_hy_dn
        (( cur_hy_up >= prev_hy_up )) && delta_hy_up=$(( cur_hy_up - prev_hy_up )) || delta_hy_up=$cur_hy_up
        (( cur_hy_dn >= prev_hy_dn )) && delta_hy_dn=$(( cur_hy_dn - prev_hy_dn )) || delta_hy_dn=$cur_hy_dn
        local delta_hy=$(( delta_hy_up + delta_hy_dn ))

        # RATTRAPAGE AUTOMATIQUE
        local recovery_hy=0
        if (( cur_hy > 0 )); then
            local total_sent_hy=0
            for sf in "$SENT_DIR"/udp_hysteria_*.sent; do
                [[ -f "$sf" ]] || continue
                local sv; sv=$(cat "$sf" 2>/dev/null)
                [[ "$sv" =~ ^[0-9]+$ ]] && total_sent_hy=$(( total_sent_hy + sv ))
            done
            local gap_hy=$(( cur_hy - total_sent_hy ))
            if (( gap_hy > 10485760 )); then
                recovery_hy=$gap_hy
                echo "[$(TS)] [UDP-hysteria] RATTRAPAGE : gap=$(( gap_hy / 1048576 ))MB" >> "$LOG_FILE"
            fi
        fi

        echo "$cur_hy_up" > "$snap_hy_up"
        echo "$cur_hy_dn" > "$snap_hy_dn"
        local effective_hy_up=$(( delta_hy_up + recovery_hy ))
        local effective_hy_dn=$delta_hy_dn
        local effective_hy=$(( effective_hy_up + effective_hy_dn ))
        echo "[$(TS)] [UDP-hysteria] up=$cur_hy_up dn=$cur_hy_dn delta_up=$delta_hy_up delta_dn=$delta_hy_dn" >> "$LOG_FILE"

        if (( effective_hy > 0 )); then
            local active_users=()
            while IFS='|' read -r username _pass expire; do
                [[ -z "$username" ]] && continue
                [[ "$expire" < "$today" ]] && continue
                active_users+=("$username")
            done < "$hy_uf"

            local nb=${#active_users[@]}
            if (( nb > 0 )); then
                local share_up=$(( effective_hy_up / nb ))
                local share_dn=$(( effective_hy_dn / nb ))
                local share=$(( share_up + share_dn ))

                for username in "${active_users[@]}"; do
                    local usagefile="$BW_DIR/udp_hysteria_${username}.usage"
                    local accum=0
                    [[ -f "$usagefile" ]] && accum=$(cat "$usagefile" 2>/dev/null)
                    [[ ! "$accum" =~ ^[0-9]+$ ]] && accum=0
                    accum=$(( accum + share ))
                    echo "$accum" > "$usagefile"

                    local sentfile="$SENT_DIR/udp_hysteria_${username}.sent"
                    local last_sent=0
                    [[ -f "$sentfile" ]] && last_sent=$(cat "$sentfile" 2>/dev/null)
                    [[ ! "$last_sent" =~ ^[0-9]+$ ]] && last_sent=0
                    local user_delta=$(( accum - last_sent ))
                    (( user_delta <= 0 )) && continue

                    echo "$accum" > "$sentfile"
                    [[ $first -eq 0 ]] && json+=","
                    json+="{\"username\":\"${username}\",\"upload_bytes\":${share_up},\"download_bytes\":${share_dn}}"
                    first=0; has_data=1
                    echo "[$(TS)] [UDP-hysteria] $username +$(( user_delta / 1048576 ))MB (total: $(( accum / 1048576 ))MB)" >> "$LOG_FILE"
                done
            fi
        fi
    fi

    json+="]}"
    if [[ $has_data -eq 1 ]]; then
        echo "[$(TS)] [UDP] Envoi stats panel..." >> "$LOG_FILE"
        send_stats "$json"
    else
        echo "[$(TS)] [UDP] Aucun nouveau trafic UDP" >> "$LOG_FILE"
    fi
}

echo "[$(TS)] Collecte des stats de trafic..." >> "$LOG_FILE"
collect_xray_traffic
collect_v2ray_traffic
collect_ssh_traffic
collect_udp_traffic

# ==========================================
# SECTION 1 : Verification quota data
# ==========================================
check_quota() {
    if [[ $MYSQL_OK -eq 0 ]]; then
        echo "[$(TS)] [QUOTA] MySQL non accessible — quota ignore" >> "$LOG_FILE"
        return
    fi
    echo "[$(TS)] Verification des quotas..." >> "$LOG_FILE"

    _block_xray() {
        local username="$1" uuid="$2" proto="$3"
        local cfg="/etc/xray/config.json"; [[ ! -f "$cfg" ]] && return
        local tmp; tmp=$(mktemp)
        if [[ "$proto" == "trojan" ]]; then
            jq --arg u "$username" '
              .inbounds |= map(if .protocol=="trojan" then
                .settings.clients |= map(select(.password != $u and .email != $u))
              else . end)' "$cfg" > "$tmp" && mv "$tmp" "$cfg" || rm -f "$tmp"
        else
            jq --arg id "$uuid" --arg em "$username" '
              .inbounds |= map(if (.protocol=="vmess" or .protocol=="vless") then
                .settings.clients |= map(select(.id != $id and .email != $em))
              else . end)' "$cfg" > "$tmp" && mv "$tmp" "$cfg" || rm -f "$tmp"
        fi
        systemctl restart xray 2>/dev/null || true
    }
    _block_v2ray() {
        local username="$1" uuid="$2"
        local cfg="${V2RAY_CONFIG:-/etc/v2ray/config.json}"; [[ ! -f "$cfg" ]] && return
        local tmp; tmp=$(mktemp)
        jq --arg id "$uuid" --arg em "$username" '
          .inbounds |= map(if .settings.clients then
            .settings.clients |= map(select(.id != $id and .email != $em))
          else . end)' "$cfg" > "$tmp" && mv "$tmp" "$cfg" || rm -f "$tmp"
        systemctl restart v2ray 2>/dev/null || true
    }
    _block_ssh()      { passwd -l "$1" 2>/dev/null || true; }
    _block_zivpn() {
        local u="$1" f="/etc/zivpn/users.list" c="/etc/zivpn/config.json"
        local blocked_dir="/etc/zivpn/blocked"
        [[ ! -f "$f" ]] && return
        mkdir -p "$blocked_dir"
        # Sauvegarder la ligne de l'utilisateur avant de la retirer
        local user_line
        user_line=$(grep "^${u}|" "$f" 2>/dev/null || true)
        if [[ -n "$user_line" ]]; then
            echo "$user_line" > "${blocked_dir}/${u}.blocked"
            chmod 600 "${blocked_dir}/${u}.blocked"
        fi
        # Retirer de users.list
        sed -i "/^${u}|/d" "$f"
        # Resynchroniser config.json
        local pw; pw=$(awk -F'|' -v t="$TODAY" '$3>=t {print $2}' "$f" | sort -u | paste -sd, -)
        [[ -n "$pw" ]] && { local tmp; tmp=$(mktemp)
            jq --arg p "$pw" '.auth.config=($p|split(","))' "$c" > "$tmp" && mv "$tmp" "$c" || rm -f "$tmp"; }
        systemctl restart zivpn 2>/dev/null || true
        echo "[$(TS)] [BLOCK-ZIVPN] $u bloqué — password sauvegardé dans ${blocked_dir}/${u}.blocked" >> "$LOG_FILE"
    }
    _block_hysteria() {
        local u="$1" f="/etc/hysteria/users.txt" c="/etc/hysteria/config.json"
        local blocked_dir="/etc/hysteria/blocked"
        [[ ! -f "$f" ]] && return
        mkdir -p "$blocked_dir"
        # Sauvegarder la ligne de l'utilisateur avant de la retirer
        local user_line
        user_line=$(grep "^${u}|" "$f" 2>/dev/null || true)
        if [[ -n "$user_line" ]]; then
            echo "$user_line" > "${blocked_dir}/${u}.blocked"
            chmod 600 "${blocked_dir}/${u}.blocked"
        fi
        # Retirer de users.txt
        sed -i "/^${u}|/d" "$f"
        # Resynchroniser config.json
        local pw; pw=$(awk -F'|' -v t="$TODAY" '$3>=t {print $2}' "$f" | sort -u | paste -sd, -)
        [[ -n "$pw" ]] && { local tmp; tmp=$(mktemp)
            jq --arg p "$pw" '.auth.config=($p|split(","))' "$c" > "$tmp" && mv "$tmp" "$c" || rm -f "$tmp"; }
        systemctl restart hysteria 2>/dev/null || true
        echo "[$(TS)] [BLOCK-HYSTERIA] $u bloqué — password sauvegardé dans ${blocked_dir}/${u}.blocked" >> "$LOG_FILE"
    }

    _do_block() {
        local cid="$1" username="$2" uuid="$3" tunnel="$4"
        case "$tunnel" in
            vless|vmess)                                   _block_xray "$username" "$uuid" "$tunnel" ;;
            trojan)                                        _block_xray "$username" "$username" "trojan" ;;
            v2ray-fastdns)                                 _block_v2ray "$username" "$uuid" ;;
            ssh-multi|ssh-ws|ssh-slowdns|ssh-ssl|ssh-udp) _block_ssh "$username" ;;
            udp-zivpn)                                     _block_zivpn "$username" ;;
            udp-hysteria)                                  _block_hysteria "$username" ;;
            *) echo "[$(TS)] [QUOTA] tunnel inconnu: $tunnel ($username)" >> "$LOG_FILE" ;;
        esac
        mysql_query "UPDATE clients SET quota_blocked=1, is_active=0 WHERE id=${cid};" || true
        echo "[$(TS)] [QUOTA] BLOQUE $username ($tunnel) — quota depasse" >> "$LOG_FILE"
    }

    # Clients dépassant leur quota
    local blocked=0
    while IFS=$'\t' read -r cid username uuid tunnel data_limit total_bytes; do
        [[ -z "$username" ]] && continue
        local used_gb; used_gb=$(awk "BEGIN {printf \"%.2f\", $total_bytes/1073741824}")
        echo "[$(TS)] [QUOTA] $username — ${used_gb}Go / ${data_limit}Go" >> "$LOG_FILE"
        _do_block "$cid" "$username" "$uuid" "$tunnel"
        (( blocked++ ))
    done < <(mysql_query "
        SELECT c.id, c.username, c.uuid, c.tunnel_type, c.data_limit_gb,
               COALESCE(SUM(u.upload_bytes+u.download_bytes),0) AS total_bytes
        FROM clients c
        LEFT JOIN usage_stats u ON u.client_id=c.id
        WHERE c.data_limit_gb > 0 AND c.is_active=1 AND c.quota_blocked=0 AND c.expires_at > NOW()
        GROUP BY c.id
        HAVING total_bytes >= (c.data_limit_gb * 1073741824);")

    [[ $blocked -gt 0 ]] \
        && echo "[$(TS)] [QUOTA] $blocked client(s) bloque(s)" >> "$LOG_FILE" \
        || echo "[$(TS)] [QUOTA] Aucun quota client depasse"   >> "$LOG_FILE"

    # Revendeurs dépassant leur quota
    local r_blocked=0
    while IFS=$'\t' read -r rid r_user r_limit r_total; do
        [[ -z "$r_user" ]] && continue
        local r_used; r_used=$(awk "BEGIN {printf \"%.2f\", $r_total/1073741824}")
        echo "[$(TS)] [QUOTA] Revendeur $r_user — ${r_used}Go / ${r_limit}Go" >> "$LOG_FILE"
        while IFS=$'\t' read -r cid c_user c_uuid c_tunnel; do
            [[ -z "$c_user" ]] && continue
            _do_block "$cid" "$c_user" "$c_uuid" "$c_tunnel"
        done < <(mysql_query "
            SELECT id,username,uuid,tunnel_type
            FROM clients
            WHERE reseller_id=${rid} AND is_active=1 AND quota_blocked=0;")
        (( r_blocked++ ))
    done < <(mysql_query "
        SELECT r.id, r.username, r.data_limit_gb,
               COALESCE(SUM(u.upload_bytes+u.download_bytes),0) AS total_bytes
        FROM resellers r
        LEFT JOIN usage_stats u ON u.reseller_id=r.id
        WHERE r.data_limit_gb>0 AND r.is_active=1 AND r.expires_at > NOW()
        GROUP BY r.id
        HAVING total_bytes >= (r.data_limit_gb * 1073741824);")

    [[ $r_blocked -gt 0 ]] \
        && echo "[$(TS)] [QUOTA] $r_blocked revendeur(s) bloque(s)" >> "$LOG_FILE"
}

check_quota

# ==========================================
# 1. Nettoyage V2Ray
# ==========================================
USER_DB="/etc/v2ray/utilisateurs.json"
CONFIG="/etc/v2ray/config.json"

if [[ -f "$USER_DB" && -f "$CONFIG" ]]; then
    echo "[$(TS)] Nettoyage V2Ray expires" >> "$LOG_FILE"
    uuids_expire=$(jq -r --arg today "$TODAY" '.[] | select(.expire < $today) | .uuid' "$USER_DB")
    if [[ -n "$(echo "$uuids_expire" | tr -d '[:space:]')" ]]; then
        tmpfile=$(mktemp)
        jq --argjson uuids "$(echo "$uuids_expire" | jq -R -s -c 'split("\n")[:-1]')" '
        .inbounds |= map(if .protocol=="vless" then
            .settings.clients |= map(select(.id as $id | $uuids | index($id) | not))
        else . end)' "$CONFIG" > "$tmpfile" && mv "$tmpfile" "$CONFIG"
        jq --arg today "$TODAY" '[.[] | select(.expire >= $today)]' "$USER_DB" \
            > "$USER_DB.tmp" && mv "$USER_DB.tmp" "$USER_DB"
        systemctl restart v2ray
        echo "[$(TS)] V2Ray nettoye et redemarre" >> "$LOG_FILE"
    else
        echo "[$(TS)] Aucun V2Ray expire" >> "$LOG_FILE"
    fi
else
    echo "[$(TS)] Fichiers V2Ray introuvables, ignore" >> "$LOG_FILE"
fi

# ==========================================
# 2. Nettoyage ZIVPN
# ==========================================
clean_zivpn_users() {
    local ZIVPN_USER_FILE="/etc/zivpn/users.list"
    local ZIVPN_CONFIG="/etc/zivpn/config.json"
    [[ ! -f "$ZIVPN_USER_FILE" || ! -f "$ZIVPN_CONFIG" ]] && return
    echo "[$(TS)] Nettoyage ZIVPN expires" >> "$LOG_FILE"
    local NUM_BEFORE; NUM_BEFORE=$(wc -l < "$ZIVPN_USER_FILE")
    local TMP_FILE; TMP_FILE=$(mktemp)
    awk -F'|' -v today="$TODAY" '$3>=today {print $0}' "$ZIVPN_USER_FILE" > "$TMP_FILE" || true
    mv "$TMP_FILE" "$ZIVPN_USER_FILE"
    chmod 600 "$ZIVPN_USER_FILE"
    local PASSWORDS; PASSWORDS=$(awk -F'|' -v today="$TODAY" '$3>=today {print $2}' \
        "$ZIVPN_USER_FILE" | sort -u | paste -sd, -)
    local tmp; tmp=$(mktemp)
    if jq --arg p "$PASSWORDS" '.auth.config=($p|split(","))' "$ZIVPN_CONFIG" > "$tmp" 2>/dev/null \
        && jq empty "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$ZIVPN_CONFIG"
        local NUM_AFTER; NUM_AFTER=$(wc -l < "$ZIVPN_USER_FILE")
        [[ "$NUM_AFTER" -lt "$NUM_BEFORE" ]] && systemctl restart zivpn
        echo "[$(TS)] ZIVPN nettoye" >> "$LOG_FILE"
    else
        echo "[$(TS)] Erreur JSON ZIVPN" >> "$LOG_FILE"; rm -f "$tmp"
    fi
}

# ==========================================
# 3. Nettoyage Xray
# ==========================================
clean_xray_users() {
    local XRAY_USERS="/etc/xray/users.json"
    local XRAY_CONFIG="/etc/xray/config.json"
    local XRAY_EXPIRY="/etc/xray/users_expiry.list"
    [[ ! -f "$XRAY_USERS" || ! -f "$XRAY_CONFIG" ]] && return
    echo "[$(TS)] Nettoyage Xray expires" >> "$LOG_FILE"
    local expired_vmess expired_vless expired_trojan
    expired_vmess=$(jq  -r --arg t "$TODAY" '.vmess[]?  | select(.expire < $t) | .uuid'     "$XRAY_USERS")
    expired_vless=$(jq  -r --arg t "$TODAY" '.vless[]?  | select(.expire < $t) | .uuid'     "$XRAY_USERS")
    expired_trojan=$(jq -r --arg t "$TODAY" '.trojan[]? | select(.expire < $t) | .password' "$XRAY_USERS")
    if [[ -z "$expired_vmess$expired_vless$expired_trojan" ]]; then
        echo "[$(TS)] Aucun Xray expire" >> "$LOG_FILE"; return
    fi
    local tmp_c; tmp_c=$(mktemp)
    local tmp_u; tmp_u=$(mktemp)
    jq --argjson ids "$(printf '%s\n%s\n' "$expired_vmess" "$expired_vless" \
            | jq -R -s -c 'split("\n")[:-1]')" \
       --argjson pw "$(printf '%s\n' "$expired_trojan" | jq -R -s -c 'split("\n")[:-1]')" '
    .inbounds |= map(
        if .protocol=="vmess" or .protocol=="vless" then
            .settings.clients |= map(select(.id as $id | $ids | index($id) | not))
        elif .protocol=="trojan" then
            .settings.clients |= map(select(.password as $p | $pw | index($p) | not))
        else . end)' "$XRAY_CONFIG" > "$tmp_c" && mv "$tmp_c" "$XRAY_CONFIG"
    jq --arg t "$TODAY" '
        .vmess  |= map(select(.expire >= $t)) |
        .vless  |= map(select(.expire >= $t)) |
        .trojan |= map(select(.expire >= $t))' "$XRAY_USERS" > "$tmp_u" && mv "$tmp_u" "$XRAY_USERS"
    [[ -f "$XRAY_EXPIRY" ]] && sed -i "/|$TODAY/d" "$XRAY_EXPIRY"
    systemctl restart xray
    echo "[$(TS)] Xray nettoye et redemarre" >> "$LOG_FILE"
}

# ==========================================
# 4. Nettoyage Hysteria
# ==========================================
clean_hysteria_users() {
    local HYSTERIA_USER_FILE="/etc/hysteria/users.txt"
    local HYSTERIA_CONFIG="/etc/hysteria/config.json"
    echo "[$(TS)] Nettoyage Hysteria" >> "$LOG_FILE"
    [[ ! -f "$HYSTERIA_USER_FILE" ]] && {
        echo "[$(TS)] users.txt Hysteria introuvable" >> "$LOG_FILE"; return; }
    local NUM_BEFORE; NUM_BEFORE=$(wc -l < "$HYSTERIA_USER_FILE")
    local EXPIRED; EXPIRED=$(awk -F'|' -v today="$TODAY" '$3<today {print $0}' "$HYSTERIA_USER_FILE")
    if [[ -z "$EXPIRED" ]]; then
        echo "[$(TS)] Aucun Hysteria expire" >> "$LOG_FILE"; return
    fi
    while IFS='|' read -r user _pass expire; do
        echo "[$(TS)] Supprime Hysteria: $user (expire=$expire)" >> "$LOG_FILE"
    done <<< "$EXPIRED"
    awk -F'|' -v today="$TODAY" '$3>=today' "$HYSTERIA_USER_FILE" > "$HYSTERIA_USER_FILE.tmp"
    mv "$HYSTERIA_USER_FILE.tmp" "$HYSTERIA_USER_FILE"
    chmod 600 "$HYSTERIA_USER_FILE"
    local PASSWORDS; PASSWORDS=$(awk -F'|' -v today="$TODAY" '$3>=today {print $2}' \
        "$HYSTERIA_USER_FILE" | sort -u | paste -sd, -)
    local tmp; tmp=$(mktemp)
    if jq --arg p "$PASSWORDS" '.auth.config=($p|split(","))' "$HYSTERIA_CONFIG" > "$tmp" \
        && jq empty "$tmp" >/dev/null 2>&1; then
        mv "$tmp" "$HYSTERIA_CONFIG"
        local NUM_AFTER; NUM_AFTER=$(wc -l < "$HYSTERIA_USER_FILE")
        [[ "$NUM_AFTER" -lt "$NUM_BEFORE" ]] && systemctl restart hysteria
        echo "[$(TS)] Hysteria nettoye et redemarre" >> "$LOG_FILE"
    else
        echo "[$(TS)] Erreur JSON Hysteria" >> "$LOG_FILE"; rm -f "$tmp"
    fi
}

clean_zivpn_users
clean_xray_users
clean_hysteria_users

echo "[$(TS)] Termine" >> "$LOG_FILE"
echo "[$(TS)] ============================================" >> "$LOG_FILE"