#!/bin/bash
set -euo pipefail

CYAN="\u001B[1;36m"; GREEN="\u001B[1;32m"
YELLOW="\u001B[1;33m"; RED="\u001B[1;31m"; RESET="\u001B[0m"

[[ "$EUID" -ne 0 ]] && { echo -e "${RED}❌ Exécutez en root${RESET}"; exit 1; }

echo -e "${CYAN}=== Installation V2Ray TCP BRUT (Port 5401) ===${RESET}"
echo -n "IP/Domaine VPS : "
read domaine

touch /var/log/v2ray_install.log
chmod 640 /var/log/v2ray_install.log

echo "📥 Téléchargement V2Ray..."
apt update -y >/dev/null 2>&1 || true
apt install -y jq unzip netfilter-persistent >/dev/null 2>&1 || true

V2RAY_TMP=$(mktemp)
wget -q https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip -O "$V2RAY_TMP"

# Vérification taille minimale (> 5 Mo)
FILESIZE=$(stat -c%s "$V2RAY_TMP")
if [[ "$FILESIZE" -lt 5242880 ]]; then
  echo -e "${RED}❌ Binaire corrompu ($FILESIZE octets)${RESET}"
  rm -f "$V2RAY_TMP"; exit 1
fi

# Vérification SHA256 depuis le fichier de hash officiel
SHA256_TMP=$(mktemp)
wget -q https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip.sha256sum \
  -O "$SHA256_TMP" 2>/dev/null || true
if [[ -s "$SHA256_TMP" ]]; then
  EXPECTED=$(awk '{print $1}' "$SHA256_TMP")
  ACTUAL=$(sha256sum "$V2RAY_TMP" | awk '{print $1}')
  if [[ "$EXPECTED" != "$ACTUAL" ]]; then
    echo -e "${RED}❌ Hash SHA256 invalide — téléchargement corrompu${RESET}"
    rm -f "$V2RAY_TMP" "$SHA256_TMP"; exit 1
  fi
  echo -e "${GREEN}✅ Hash SHA256 vérifié${RESET}"
else
  echo -e "${YELLOW}⚠️  Vérification SHA256 ignorée (fichier hash indisponible)${RESET}"
fi
rm -f "$SHA256_TMP"

rm -rf /tmp/v2ray
unzip -o "$V2RAY_TMP" -d /tmp/v2ray >/dev/null 2>&1
rm -f "$V2RAY_TMP"
mv /tmp/v2ray/v2ray /usr/local/bin/
chmod +x /usr/local/bin/v2ray

mkdir -p /etc/v2ray
echo "$domaine" > /.v2ray_domain

# ============================================================
# TUNING KERNEL TCP — réseaux mobiles instables (Afrique)
# ============================================================
tee /etc/sysctl.d/99-v2ray.conf >/dev/null <<'SYSCTL'
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_syn_retries = 3
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL

sysctl -p /etc/sysctl.d/99-v2ray.conf >/dev/null 2>&1 || true

# Vérifier si BBR a bien été appliqué
BBR_ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$BBR_ACTIVE" == "bbr" ]]; then
  echo -e "${GREEN}✅ BBR activé${RESET}"
else
  echo -e "${YELLOW}⚠️  BBR non disponible sur ce kernel ($BBR_ACTIVE) — cubic utilisé${RESET}"
fi

# ============================================================
# CONFIG V2RAY
# ============================================================
tee /etc/v2ray/config-v2only.json >/dev/null <<'EOF'
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": [
      "StatsService"
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true,
        "handshake": 8,
        "connIdle": 120,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 512
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10086,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "vless-tcp",
      "port": 5401,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "00000000-0000-0000-0000-000000000001"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "sockopt": {
          "tcpKeepAliveInterval": 60,
          "tcpNoDelay": true,
          "mark": 255
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "streamSettings": {
        "sockopt": {
          "tcpKeepAliveInterval": 60,
          "tcpNoDelay": true,
          "mark": 255
        }
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      }
    ]
  }
}
EOF

cp /etc/v2ray/config-v2only.json /etc/v2ray/config.json

# ============================================================
# SERVICE SYSTEMD
# ============================================================
tee /etc/systemd/system/v2ray.service >/dev/null <<'EOF'
[Unit]
Description=V2Ray Service
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v2ray run -config /etc/v2ray/config.json
Restart=always
RestartSec=5
StartLimitBurst=0
LimitNOFILE=65536
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=10

[Install]
WantedBy=multi-user.target
EOF

# ============================================================
# FIREWALL
# ============================================================
# Ouvrir le port TCP 444 (table nftables dédiée)
    /usr/local/bin/init-nftables.sh

    TMP_NFT=$(mktemp)
    cat > "$TMP_NFT" << 'EOF'
table inet v2ray {
    chain input {
        type filter hook input priority 0; policy accept;
        tcp dport 5401 accept
    }
    chain output {
        type filter hook output priority 0; policy accept;
        tcp sport 5401 accept
    }
}
EOF

    if nft -c -f "$TMP_NFT"; then
        mv "$TMP_NFT" /etc/nftables/v2ray.nft
        systemctl daemon-reload
        systemctl enable --now nftables-tunnel@v2ray.service
        systemctl restart nftables-tunnel@v2ray.service
        echo "[OK] Port TCP 5401 autorisé (table nftables v2ray)"
    else
        echo "[ERREUR] Erreur de syntaxe nftables — table v2ray non appliquée"
        rm -f "$TMP_NFT"
    fi

# ============================================================
# LOGROTATE — évite saturation disque sur 6-12 mois
# ============================================================
tee /etc/logrotate.d/v2ray >/dev/null <<'EOF'
/var/log/v2ray_install.log
/var/log/v2ray_watchdog.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF

# ============================================================
# CRON WATCHDOG
# ============================================================
CRON_V2="*/15 * * * * systemctl is-active --quiet v2ray || systemctl restart v2ray >> /var/log/v2ray_watchdog.log 2>&1"
CRON_PURGE="0 * * * * bash /root/Kighmu/v2ray_manager.sh cron >> /var/log/v2ray_watchdog.log 2>&1"

( crontab -l 2>/dev/null \
    | grep -v "v2ray"; \
  echo "$CRON_V2"; \
  echo "$CRON_PURGE" \
) | crontab -

systemctl daemon-reload
systemctl enable v2ray.service
systemctl restart v2ray.service

sleep 2
if systemctl is-active --quiet v2ray.service && ss -tln | grep -q :5401; then
  echo -e "${GREEN}🎉 V2Ray actif sur le port 5401 !${RESET}"
  echo -e "${GREEN}✅ Restart=always + watchdog 15 min + BBR + logrotate actifs${RESET}"
else
  echo -e "${RED}❌ Échec du démarrage V2Ray${RESET}"
  journalctl -u v2ray.service -n 20 --no-pager
fi

read -p "Appuyez sur Entrée pour revenir au menu..."
