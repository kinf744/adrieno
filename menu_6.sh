#!/bin/bash

CONFIG_FILE="/etc/xray/config.json"
USERS_FILE="/etc/xray/users.json"
DOMAIN=""

RED="\u001B[31m"; GREEN="\u001B[32m"; YELLOW="\u001B[33m"
MAGENTA="\u001B[35m"; CYAN="\u001B[36m"; BOLD="\u001B[1m"; WHITE_BOLD="\u001B[1;37m"
RESET="\u001B[0m"

# === PORTS ===
PORT_NTLS=8880; PORT_TLS=8443

print_header() {
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
  echo -e "${CYAN}       ${BOLD}${MAGENTA}Xray – Gestion des Tunnels${RESET}${CYAN}${RESET}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}"
}

afficher_utilisateurs_xray() {
    [[ ! -f "$USERS_FILE" ]] && { echo -e "${RED}Fichier utilisateurs introuvable.${RESET}"; return 1; }
    local v=$(jq '[.vmess[]?.uuid]  | unique | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local l=$(jq '[.vless[]?.uuid]  | unique | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local t=$(jq '[.trojan[]?.uuid] | unique | length' "$USERS_FILE" 2>/dev/null || echo 0)
    local s=$(jq '[.shadow[]?.password] | unique | length' "$USERS_FILE" 2>/dev/null || echo 0)
    echo -e "${WHITE_BOLD}Utilisateurs :${RESET}"
    echo -e "  VMess [${YELLOW}$v${RESET}]  VLESS [${YELLOW}$l${RESET}]  Trojan [${YELLOW}$t${RESET}]  Shadow [${YELLOW}$s${RESET}]"
}

afficher_appareils_connectes() {
  local ips=$(ss -tn state established '( sport = :8443 or sport = :8880 )' 2>/dev/null | awk 'NR>1{print $5}' | cut -d: -f1 | sort -u | grep -v '^$' 2>/dev/null)
  if [[ -n "$ips" ]]; then
    local count=$(echo "$ips" | wc -l)
    echo -e "${WHITE_BOLD}Appareils connectés :${RESET}  ${YELLOW}${count}${RESET}"
    while IFS= read -r ip; do
      echo -e "  └─ ${CYAN}$ip${RESET}"
    done <<< "$ips"
  else
    echo -e "${WHITE_BOLD}Appareils connectés :${RESET}  ${YELLOW}0${RESET}"
  fi
}

format_bytes() {
  local bytes=$1
  (( bytes < 1024 )) && { printf "%.2f B" "$bytes"; return; }
  (( bytes < 1048576 )) && { awk "BEGIN{printf \"%.2f KB\", $bytes/1024}"; return; }
  (( bytes < 1073741824 )) && { awk "BEGIN{printf \"%.2f MB\", $bytes/1048576}"; return; }
  (( bytes < 1099511627776 )) && { awk "BEGIN{printf \"%.2f GB\", $bytes/1073741824}"; return; }
  awk "BEGIN{printf \"%.2f TB\", $bytes/1099511627776}"
}

print_consommation_xray() {
  if ! systemctl is-active --quiet xray; then
    echo -e "${WHITE_BOLD}Consommation :${RESET}  ${RED}Xray inactif${RESET}"
    return
  fi
  local raw_stats=$("/usr/local/bin/xray" api statsquery --server="127.0.0.1:10085" 2>/dev/null)
  [[ -z "$raw_stats" ]] && { echo -e "${WHITE_BOLD}Consommation :${RESET}  ${YELLOW}API indisponible${RESET}"; return; }

  local parsed=$(echo "$raw_stats" | python3 -c "
import sys, json
data = json.load(sys.stdin)
up = dn = 0
for s in data.get('stat', []):
    name = s.get('name', '')
    val = s.get('value', 0)
    if 'inbound>>>' in name and '>>>traffic>>>' in name:
        if 'uplink' in name:   up += val
        if 'downlink' in name: dn += val
print(f'{up} {dn}')
" 2>/dev/null)
  [[ -z "$parsed" ]] && { echo -e "${WHITE_BOLD}Consommation :${RESET}  ${YELLOW}Erreur parsing${RESET}"; return; }

  local up_bytes=$(echo "$parsed" | cut -d' ' -f1)
  local dn_bytes=$(echo "$parsed" | cut -d' ' -f2)

  echo -e "${WHITE_BOLD}Consommation Xray :${RESET}  ↑ ${GREEN}$(format_bytes $up_bytes)${RESET} / ↓ ${GREEN}$(format_bytes $dn_bytes)${RESET} / ∑ ${GREEN}$(format_bytes $((up_bytes+dn_bytes)))${RESET}"
}

afficher_xray_actifs() {
  if ! systemctl is-active --quiet xray; then echo -e "${RED}Xray inactif${RESET}"; return; fi
  echo -e "${WHITE_BOLD}Xray actif :${RESET}  Port NTLS [${YELLOW}$PORT_NTLS${RESET}]  Port TLS [${YELLOW}$PORT_TLS${RESET}]"
  local haproxy_st=$(systemctl is-active haproxy 2>/dev/null)
  local nginx_st=$(systemctl is-active nginx 2>/dev/null)
  echo -e "  ${WHITE_BOLD}HAProxy${RESET} [$([ "$haproxy_st" = "active" ] && echo -e "${GREEN}Actif${RESET}" || echo -e "${RED}Inactif${RESET}")]  ${WHITE_BOLD}Nginx${RESET} [$([ "$nginx_st" = "active" ] && echo -e "${GREEN}Actif${RESET}" || echo -e "${RED}Inactif${RESET}")]"
}

show_menu() {
  echo -e "${CYAN}──────────────────────────────────────────────────────────${RESET}"
  echo -e "${BOLD}${YELLOW}[01]${RESET} Installer Xray"
  echo -e "${BOLD}${YELLOW}[02]${RESET} Créer VMess"
  echo -e "${BOLD}${YELLOW}[03]${RESET} Créer VLESS"
  echo -e "${BOLD}${YELLOW}[04]${RESET} Créer Trojan"
  echo -e "${BOLD}${YELLOW}[05]${RESET} Créer Shadowsocks (Shadow)"
  echo -e "${BOLD}${YELLOW}[06]${RESET} Consommation par utilisateur"
  echo -e "${BOLD}${YELLOW}[07]${RESET} Supprimer utilisateur"
  echo -e "${BOLD}${YELLOW}[08]${RESET} Désinstallation complète"
  echo -e "${BOLD}${RED}[00]${RESET} Quitter"
  echo -e "${CYAN}──────────────────────────────────────────────────────────${RESET}"
  echo -ne "${BOLD}${YELLOW}Choix → ${RESET}"
  read -r choice
}

load_user_data() {
  if [[ -f "$USERS_FILE" ]]; then
    VMESS=$(jq -c '.vmess  // []' "$USERS_FILE")
    VLESS=$(jq -c '.vless  // []' "$USERS_FILE")
    TROJAN=$(jq -c '.trojan // []' "$USERS_FILE")
    SHADOW=$(jq -c '.shadow // []' "$USERS_FILE")
  else
    VMESS="[]"; VLESS="[]"; TROJAN="[]"; SHADOW="[]"
  fi
}

safe_write() {
    local tmp="$1" dst="$2"
    [[ ! -s "$tmp" ]] && { echo -e "${RED}Fichier vide — abandon${RESET}"; rm -f "$tmp"; return 1; }
    jq . "$tmp" >/dev/null 2>&1 || { echo -e "${RED}JSON invalide${RESET}"; rm -f "$tmp"; return 1; }
    mv "$tmp" "$dst"
}

# ================================================================
# GÉNÉRATION DE LIENS
# ================================================================
gen_links_vmess() {
  local name="$1" uuid="$2"
  local b64_tls=$(echo -n "{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$DOMAIN\",\"port\":\"$PORT_TLS\",\"id\":\"$uuid\",\"aid\":0,\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}" | base64 -w0)
  local b64_ntls=$(echo -n "{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$DOMAIN\",\"port\":\"$PORT_NTLS\",\"id\":\"$uuid\",\"aid\":0,\"net\":\"ws\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"/vmess\",\"tls\":\"none\"}" | base64 -w0)
  local b64_grpc=$(echo -n "{\"v\":\"2\",\"ps\":\"$name\",\"add\":\"$DOMAIN\",\"port\":\"$PORT_TLS\",\"id\":\"$uuid\",\"aid\":0,\"net\":\"grpc\",\"type\":\"none\",\"host\":\"$DOMAIN\",\"path\":\"vmess-grpc\",\"tls\":\"tls\",\"sni\":\"$DOMAIN\"}" | base64 -w0)
  echo -e "${CYAN}┃ TLS WS     : ${GREEN}vmess://${b64_tls}${RESET}"
  echo -e "${CYAN}┃ NTLS WS    : ${GREEN}vmess://${b64_ntls}${RESET}"
  echo -e "${CYAN}┃ TLS gRPC   : ${GREEN}vmess://${b64_grpc}${RESET}"
}

gen_links_vless() {
  local name="$1" uuid="$2"
  echo -e "${CYAN}┃ TLS WS     : ${GREEN}vless://$uuid@$DOMAIN:$PORT_TLS?security=tls&type=ws&path=/vless&host=$DOMAIN&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ NTLS WS    : ${GREEN}vless://$uuid@$DOMAIN:$PORT_NTLS?security=none&type=ws&path=/vless&host=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS XHTTP  : ${GREEN}vless://$uuid@$DOMAIN:$PORT_TLS?security=tls&type=xhttp&path=/vless-xhttp&host=$DOMAIN&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS HUpg   : ${GREEN}vless://$uuid@$DOMAIN:$PORT_TLS?security=tls&type=httpupgrade&path=/vless-hupgrade&host=$DOMAIN&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS gRPC   : ${GREEN}vless://$uuid@$DOMAIN:$PORT_TLS?mode=grpc&security=tls&type=grpc&serviceName=vless-grpc&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ NTLS TCP   : ${GREEN}vless://$uuid@$DOMAIN:$PORT_NTLS?security=none&type=tcp#$name${RESET}"
  echo -e "${CYAN}┃ TLS TCP    : ${GREEN}vless://$uuid@$DOMAIN:$PORT_TLS?security=tls&type=tcp&sni=$DOMAIN#$name${RESET}"
}

gen_links_trojan() {
  local name="$1" pw="$2"
  echo -e "${CYAN}┃ TLS WS     : ${GREEN}trojan://$pw@$DOMAIN:$PORT_TLS?security=tls&type=ws&path=/trojan&host=$DOMAIN&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ NTLS WS    : ${GREEN}trojan://$pw@$DOMAIN:$PORT_NTLS?security=none&type=ws&path=/trojan&host=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS XHTTP  : ${GREEN}trojan://$pw@$DOMAIN:$PORT_TLS?security=tls&type=xhttp&path=/trojan-xhttp&host=$DOMAIN&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS gRPC   : ${GREEN}trojan://$pw@$DOMAIN:$PORT_TLS?security=tls&type=grpc&serviceName=trojan-grpc&sni=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ NTLS TCP   : ${GREEN}trojan://$pw@$DOMAIN:$PORT_NTLS?security=none&type=tcp#$name${RESET}"
  echo -e "${CYAN}┃ TLS TCP    : ${GREEN}trojan://$pw@$DOMAIN:$PORT_TLS?security=tls&type=tcp&sni=$DOMAIN#$name${RESET}"
}

gen_links_shadow() {
  local name="$1" pw="$2"
  local b64=$(echo -n "aes-256-gcm:$pw" | base64 -w0)
  echo -e "${CYAN}┃ NTLS WS    : ${GREEN}ss://$b64@$DOMAIN:$PORT_NTLS?plugin=v2ray-plugin;path=/shadow;host=$DOMAIN#$name${RESET}"
  echo -e "${CYAN}┃ TLS WS     : ${GREEN}ss://$b64@$DOMAIN:$PORT_TLS?plugin=v2ray-plugin;path=/shadow;host=$DOMAIN;tls#$name${RESET}"
  echo -e "${CYAN}┃ TLS gRPC   : ${GREEN}ss://$b64@$DOMAIN:$PORT_TLS?plugin=v2ray-plugin;mode=grpc;serviceName=shadow-grpc;tls#$name${RESET}"
}

# ================================================================
# CRÉATION UTILISATEUR (vmess / vless / trojan / shadow)
# ================================================================
create_config() {
  local proto=$1 name=$2 days=$3 limit=$4

  if [[ -z "$DOMAIN" ]]; then
    [[ -f /etc/xray/domain ]] && DOMAIN=$(cat /etc/xray/domain) || { echo -e "${RED}Domaine non défini.${RESET}"; return 1; }
  fi
  [[ ! -f "$CONFIG_FILE" ]] && { echo -e "${RED}config.json introuvable.${RESET}"; return 1; }
  jq . "$CONFIG_FILE" >/dev/null 2>&1 || { echo -e "${RED}config.json corrompu.${RESET}"; return 1; }

  local uuid tag exp_date_iso
  uuid=$(cat /proc/sys/kernel/random/uuid)
  tag="${proto}_${name}_${uuid:0:8}"
  exp_date_iso=$(date -d "+$days days" +"%Y-%m-%d")

  # Vérifier clé proto dans users.json
  if ! jq -e ".${proto}" "$USERS_FILE" >/dev/null 2>&1; then
    local tmp=$(mktemp /tmp/users.XXXXXX)
    jq ".${proto} = []" "$USERS_FILE" > "$tmp" && safe_write "$tmp" "$USERS_FILE" || return 1
  fi

  # Ajouter à users.json
  local tmp_u=$(mktemp /tmp/users.XXXXXX)
  case "$proto" in
    shadow)
      local method="aes-256-gcm"
      jq --arg pw "$uuid" --arg name "$name" --arg tag "$tag" --arg exp "$exp_date_iso" --argjson lim "$limit" --arg meth "$method" \
        '.shadow += [{"password":$pw,"method":$meth,"name":$name,"tag":$tag,"limit_gb":$lim,"used_gb":0,"expire":$exp}]' \
        "$USERS_FILE" > "$tmp_u"
      ;;
    *)
      jq --arg id "$uuid" --arg name "$name" --arg tag "$tag" --arg exp "$exp_date_iso" --argjson lim "$limit" \
        ".${proto} += [{\"uuid\":\$id,\"email\":\$tag,\"name\":\$name,\"tag\":\$tag,\"limit_gb\":\$lim,\"used_gb\":0,\"expire\":\$exp}]" \
        "$USERS_FILE" > "$tmp_u"
      ;;
  esac
  safe_write "$tmp_u" "$USERS_FILE" || return 1

  # Ajouter à config.json
  local tmp_c=$(mktemp /tmp/config.XXXXXX)
  case "$proto" in
    vmess)
      jq --arg id "$uuid" --arg tag "$tag" \
        '(.inbounds[] | select(.protocol=="vmess") | .settings.clients) |= (. // []) + [{"id":$id,"alterId":0,"email":$tag}]' \
        "$CONFIG_FILE" > "$tmp_c"
      ;;
    vless)
      jq --arg id "$uuid" --arg tag "$tag" \
        '(.inbounds[] | select(.protocol=="vless") | .settings.clients) |= (. // []) + [{"id":$id,"email":$tag}]' \
        "$CONFIG_FILE" > "$tmp_c"
      ;;
    trojan)
      jq --arg pw "$uuid" --arg tag "$tag" \
        '(.inbounds[] | select(.protocol=="trojan") | .settings.clients) |= (. // []) + [{"password":$pw,"email":$tag}]' \
        "$CONFIG_FILE" > "$tmp_c"
      ;;
    shadow)
      jq --arg pw "$uuid" --arg tag "$tag" \
        '(.inbounds[] | select(.protocol=="shadowsocks") | .settings.clients) |= (. // []) + [{"password":$pw,"email":$tag,"method":"aes-256-gcm"}]' \
        "$CONFIG_FILE" > "$tmp_c"
      ;;
  esac

  local c_before=$(jq "[.inbounds[] | select(.protocol==\"${proto}\" // (.protocol==\"shadowsocks\" and \"${proto}\"==\"shadow\")) | .settings.clients // [] | .[]] | length" "$CONFIG_FILE" 2>/dev/null || echo 0)
  local c_after=$(jq  "[.inbounds[] | select(.protocol==\"${proto}\" // (.protocol==\"shadowsocks\" and \"${proto}\"==\"shadow\")) | .settings.clients // [] | .[]] | length" "$tmp_c" 2>/dev/null || echo 0)
  (( c_after <= c_before )) && { echo -e "${RED}Client non ajouté.${RESET}"; rm -f "$tmp_c"; return 1; }

  safe_write "$tmp_c" "$CONFIG_FILE" || return 1

  echo "$uuid|$exp_date_iso" >> /etc/xray/users_expiry.list

  # Affichage
  local proto_paths=""
  case "$proto" in
    vmess)  proto_paths="/vmess (WS), /vmess-grpc (gRPC)" ;;
    vless)  proto_paths="/vless (WS), /vless-xhttp (XHTTP), /vless-hupgrade (HUp), /vless-grpc (gRPC)" ;;
    trojan) proto_paths="/trojan (WS), /trojan-xhttp (XHTTP), /trojan-grpc (gRPC)" ;;
    shadow) proto_paths="/shadow (WS), /shadow-grpc (gRPC)" ;;
  esac

  echo; echo -e "${CYAN}==============================${RESET}"
  echo -e "${BOLD}  ${proto^^} – $name${RESET}"
  echo -e "${CYAN}==============================${RESET}"
  echo -e "  Domaine    : $DOMAIN"
  echo -e "  UUID/Pwd   : $uuid"
  echo -e "  Path(s)    : ${CYAN}$proto_paths${RESET}"
  echo -e "  Utilisateur : $name"
  echo -e "  Méthode    : $([ "$proto" == "shadow" ] && echo "aes-256-gcm" || echo "-")"
  echo -e "  Limite     : $limit Go"
  echo -e "  Expire     : $exp_date_iso"
  echo
  echo -e "${CYAN}●━━━━━━ Liens ━━━━━━━━━━━━━━━━━━━●${RESET}"
  case "$proto" in
    vmess)  gen_links_vmess "$name" "$uuid" ;;
    vless)  gen_links_vless "$name" "$uuid" ;;
    trojan) gen_links_trojan "$name" "$uuid" ;;
    shadow) gen_links_shadow "$name" "$uuid" ;;
  esac
  echo -e "${CYAN}●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━●${RESET}"
  echo

  # Restart Xray
  systemctl restart xray
  sleep 2
  if systemctl is-active --quiet xray; then
    echo -e "${GREEN}Xray redémarré.${RESET}"
  else
    echo -e "${RED}Xray ne répond pas.${RESET}"
    journalctl -u xray -n 10 --no-pager
  fi
}

# ================================================================
# CONSOMMATION PAR UTILISATEUR
# ================================================================
afficher_quota_par_utilisateur() {
  local api_addr="127.0.0.1:10085" xray_bin="/usr/local/bin/xray"
  ! systemctl is-active --quiet xray && { echo -e "${RED}Xray inactif.${RESET}"; return 1; }
  [[ ! -x "$xray_bin" ]] && { echo -e "${RED}Binaire Xray introuvable.${RESET}"; return 1; }
  [[ ! -f "$USERS_FILE" ]] && { echo -e "${RED}users.json introuvable.${RESET}"; return 1; }

  local raw_stats=$("$xray_bin" api statsquery --server="$api_addr" --pattern="user>>>" 2>/dev/null)
  [[ -z "$raw_stats" ]] && raw_stats=$("$xray_bin" api statsquery --server="$api_addr" 2>/dev/null)

  echo; echo -e "${CYAN}━━━ Consommation par utilisateur ━━━${RESET}"
  local printed=0

  for proto in vmess vless trojan shadow; do
    local users_json=$(jq -c ".${proto} // [] | .[]" "$USERS_FILE" 2>/dev/null)
    [[ -z "$users_json" ]] && continue
    local first=1

    while IFS= read -r user_obj; do
      local tag name expire limit_gb pw
      tag=$(echo "$user_obj"     | jq -r '.tag // .email // ""')
      name=$(echo "$user_obj"    | jq -r '.name // ""')
      expire=$(echo "$user_obj"  | jq -r '.expire // "N/A"')
      limit_gb=$(echo "$user_obj"| jq -r '.limit_gb // 0')
      pw=$(echo "$user_obj"      | jq -r '.password // ""')
      [[ -z "$tag" ]] && continue
      [[ -z "$name" ]] && name="$tag"

      local up_bytes=0 down_bytes=0 tmp
      [[ -n "$raw_stats" ]] && {
        tmp=$(echo "$raw_stats" | awk -v t="user>>>$tag>>>traffic>>>uplink"   '$0~"name: \""t"\""{f=1;next} f&&/value:/{gsub(/[^0-9]/,"",$2);print $2;f=0}')
        [[ "$tmp" =~ ^[0-9]+$ ]] && up_bytes="$tmp"
        tmp=$(echo "$raw_stats" | awk -v t="user>>>$tag>>>traffic>>>downlink" '$0~"name: \""t"\""{f=1;next} f&&/value:/{gsub(/[^0-9]/,"",$2);print $2;f=0}')
        [[ "$tmp" =~ ^[0-9]+$ ]] && down_bytes="$tmp"
      }

      local total_bytes=$(( up_bytes + down_bytes ))
      local total_fmt=$(format_bytes "$total_bytes")
      local up_fmt=$(format_bytes "$up_bytes")
      local down_fmt=$(format_bytes "$down_bytes")

      local bar_str=""
      if (( limit_gb > 0 )); then
        local total_gb=$(awk "BEGIN{printf \"%.3f\", $total_bytes/1073741824}")
        local pct=$(awk -v t="$total_gb" -v l="$limit_gb" 'BEGIN{v=int(t*100/l);if(v>100)v=100;print v}')
        local filled=$(( pct * 20 / 100 )) empty=$(( 20 - filled ))
        local c="$GREEN"; [[ $pct -ge 70 ]] && c="$YELLOW"; [[ $pct -ge 90 ]] && c="$RED"
        bar_str="$c["; for ((i=0;i<filled;i++)); do bar_str+="█"; done; for ((i=0;i<empty;i++)); do bar_str+="░"; done
        bar_str+="]${RESET} ${c}${pct}%${RESET}"
      fi

      (( first )) && { echo; echo -e "  ${BOLD}${CYAN}── ${proto^^} ────────────────${RESET}"; first=0; }
      echo -e "  ${BOLD}${name}${RESET}  ${MAGENTA}[$tag]${RESET}"
      echo -e "    ↑ $up_fmt  ↓ $down_fmt  ∑ ${YELLOW}$total_fmt${RESET} / ${limit_gb} Go  ${bar_str:-${YELLOW}(illimité)${RESET}}"
      echo -e "    Expire : $expire"
      (( printed++ ))
    done <<< "$users_json"
  done

  (( printed == 0 )) && echo -e "  ${YELLOW}Aucun utilisateur.${RESET}"
  [[ -z "$raw_stats" ]] && echo -e "  ${RED}API stats indisponible.${RESET}"
  echo
}

# ================================================================
# SUPPRESSION UTILISATEUR
# ================================================================
delete_user_by_number() {
    [[ ! -f "$USERS_FILE" ]] && { echo -e "${RED}users.json introuvable.${RESET}"; return 1; }
    local users=() protos=() names=()

    for proto in vmess vless trojan shadow; do
      while IFS= read -r line; do
        local uid uname
        if [[ "$proto" == "shadow" ]]; then
          uid=$(echo "$line"  | jq -r '.password // ""')
          uname=$(echo "$line" | jq -r '.name // .email // .password')
        else
          uid=$(echo "$line"  | jq -r '.uuid  // ""')
          uname=$(echo "$line" | jq -r '.name // .email // .uuid')
        fi
        [[ -z "$uid" ]] && continue
        users+=("$uid"); protos+=("$proto"); names+=("$uname")
      done < <(jq -c ".${proto}[]?" "$USERS_FILE" 2>/dev/null)
    done

    (( ${#users[@]} == 0 )) && { echo -e "${RED}Aucun utilisateur.${RESET}"; return 0; }

    echo; echo -e "${YELLOW}Liste des utilisateurs :${RESET}"
    for i in "${!users[@]}"; do
        echo -e "  ${BOLD}[$((i+1))]${RESET} ${protos[$i]^^} → ${names[$i]}  ${MAGENTA}(${users[$i]})${RESET}"
    done; echo

    echo -e "  ${CYAN}Exemples : 1,3,5 | 1-5 | 1 3 5 | 2,4-6${RESET}"
    read -rp "Numéro(s) à supprimer (0=annuler) : " input
    input="${input//,/ }"
    [[ "$input" == "0" ]] && { echo "Annulé."; return 0; }

    local indices=()
    for part in $input; do
      if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        for ((j=${BASH_REMATCH[1]}; j<=${BASH_REMATCH[2]}; j++)); do
          (( j > 0 && j <= ${#users[@]} )) && indices+=("$j")
        done
      elif [[ "$part" =~ ^[0-9]+$ ]] && (( part > 0 && part <= ${#users[@]} )); then
        indices+=("$part")
      fi
    done
    (( ${#indices[@]} == 0 )) && { echo -e "${RED}Aucun numéro valide.${RESET}"; return 1; }

    # Dédupliquer et trier décroissant (pour supprimer sans décaler)
    local sorted=()
    while IFS= read -r n; do sorted+=("$n"); done < <(printf "%s\n" "${indices[@]}" | sort -nu -r)

    echo -e "${YELLOW}Suppression de ${#sorted[@]} utilisateur(s)...${RESET}"
    cp "$USERS_FILE" "${USERS_FILE}.bak"
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    local tmp_u=$(mktemp /tmp/users.XXXXXX)
    cp "$USERS_FILE" "$tmp_u"

    local tmp_c=$(mktemp /tmp/config.XXXXXX)
    cp "$CONFIG_FILE" "$tmp_c"

    local removed=0
    for idx in "${sorted[@]}"; do
      local i=$(( idx - 1 ))
      local sel_id="${users[$i]}" sel_proto="${protos[$i]}" sel_name="${names[$i]}"

      if [[ "$sel_proto" == "shadow" ]]; then
        jq --arg pw "$sel_id" --arg proto "$sel_proto" '.[$proto] |= map(select(.password != $pw))' "$tmp_u" > "${tmp_u}.2" && mv "${tmp_u}.2" "$tmp_u"
        jq --arg pw "$sel_id" --arg proto "$sel_proto" '
          (.inbounds[] | select(.tag | startswith($proto))) .settings.clients |= map(select(.password != $pw))
        ' "$tmp_c" > "${tmp_c}.2" && mv "${tmp_c}.2" "$tmp_c"
      else
        jq --arg u "$sel_id" --arg proto "$sel_proto" '.[$proto] |= map(select(.uuid != $u))' "$tmp_u" > "${tmp_u}.2" && mv "${tmp_u}.2" "$tmp_u"
        jq --arg u "$sel_id" --arg proto "$sel_proto" '
          (.inbounds[] | select(.tag | startswith($proto))) .settings.clients |= map(select(.email != $u))
        ' "$tmp_c" > "${tmp_c}.2" && mv "${tmp_c}.2" "$tmp_c"
      fi
      (( removed++ ))
    done

    safe_write "$tmp_u" "$USERS_FILE" || return 1
    safe_write "$tmp_c" "$CONFIG_FILE" || return 1

    systemctl restart xray 2>/dev/null
    echo -e "${GREEN}${removed} utilisateur(s) supprimé(s).${RESET}"
}

# ================================================================
# MAIN
# ================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
choice=0
[[ -f /etc/xray/domain ]] && DOMAIN=$(cat /etc/xray/domain)

load_user_data

while true; do
  clear
  print_header
  afficher_utilisateurs_xray
  afficher_appareils_connectes
  print_consommation_xray
  afficher_xray_actifs
  show_menu

  case $choice in
    1)
      bash "$SCRIPT_DIR/xray_installe.sh"
      [[ -f /etc/xray/domain ]] && DOMAIN=$(cat /etc/xray/domain)
      load_user_data
      read -p "Appuyez sur Entrée..."
      ;;
    2)
      read -rp "Nom VMess : " n; read -rp "Durée (jours) : " d; read -rp "Limite Go (0=illimité) : " l
      [[ -n "$n" && -n "$d" ]] && create_config "vmess" "$n" "$d" "$l"
      read -p "Appuyez sur Entrée..."
      ;;
    3)
      read -rp "Nom VLESS : " n; read -rp "Durée (jours) : " d; read -rp "Limite Go (0=illimité) : " l
      [[ -n "$n" && -n "$d" ]] && create_config "vless" "$n" "$d" "$l"
      read -p "Appuyez sur Entrée..."
      ;;
    4)
      read -rp "Nom Trojan : " n; read -rp "Durée (jours) : " d; read -rp "Limite Go (0=illimité) : " l
      [[ -n "$n" && -n "$d" ]] && create_config "trojan" "$n" "$d" "$l"
      read -p "Appuyez sur Entrée..."
      ;;
    5)
      read -rp "Nom Shadow : " n; read -rp "Durée (jours) : " d; read -rp "Limite Go (0=illimité) : " l
      [[ -n "$n" && -n "$d" ]] && create_config "shadow" "$n" "$d" "$l"
      read -p "Appuyez sur Entrée..."
      ;;
    6)
      afficher_quota_par_utilisateur
      read -p "Appuyez sur Entrée..."
      ;;
    7)
      delete_user_by_number
      read -p "Appuyez sur Entrée..."
      ;;
    8)
      echo -e "${YELLOW}Désinstallation complète...${RESET}"
      read -rp "Confirmer ? (o/n) : " c
      case "$c" in
        [oO]*)
          systemctl stop xray nginx haproxy 2>/dev/null
          systemctl disable xray nginx haproxy 2>/dev/null
          for p in 8880 8443 81 8881 8444; do lsof -i tcp:$p -t 2>/dev/null | xargs -r kill -9; done
          rm -rf /etc/xray /var/log/xray /usr/local/bin/xray
          rm -f /etc/systemd/system/xray.service
          rm -f /etc/haproxy/haproxy.cfg
          rm -f /etc/nginx/conf.d/xray-tls.conf /etc/nginx/conf.d/xray-ntls.conf /etc/nginx/conf.d/acme-challenge.conf
          rm -f /etc/nginx/sites-enabled/default /etc/logrotate.d/xray
          systemctl daemon-reload
          echo -e "${GREEN}Désinstallé.${RESET}"
          ;;
      esac
      read -p "Appuyez sur Entrée..."
      ;;
    0) echo -e "${RED}Quitter.${RESET}"; break ;;
    *) echo -e "${RED}Choix invalide.${RESET}"; sleep 2 ;;
  esac
done
