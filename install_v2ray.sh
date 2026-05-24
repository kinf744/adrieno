#!/bin/bash
set -euo pipefail

CYAN="\u001B[1;36m"
GREEN="\u001B[1;32m"
YELLOW="\u001B[1;33m"
RED="\u001B[1;31m"
RESET="\u001B[0m"

echo -e "${CYAN}=== Installation V2Ray TCP BRUT (Port 5401) ===${RESET}"
echo -n "IP/Domaine VPS : "
read domaine

LOGFILE="/var/log/v2ray_install.log"
sudo touch "$LOGFILE"
sudo chmod 640 "$LOGFILE"

echo "📥 Téléchargement V2Ray..."

sudo apt update -y >/dev/null 2>&1 || true
sudo apt install -y jq unzip netfilter-persistent >/dev/null 2>&1 || true

wget -q https://github.com/v2fly/v2ray-core/releases/latest/download/v2ray-linux-64.zip -O /tmp/v2ray.zip
unzip -o /tmp/v2ray.zip -d /tmp/v2ray >/dev/null 2>&1
sudo mv /tmp/v2ray/v2ray /usr/local/bin/
sudo chmod +x /usr/local/bin/v2ray

sudo mkdir -p /etc/v2ray
echo "$domaine" | sudo tee /.v2ray_domain >/dev/null

# ======================
# CONFIG V2RAY TCP BRUT
# ======================
cat <<EOF | sudo tee /etc/v2ray/config-v2only.json >/dev/null
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
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
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "tag": "vless-tcp"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
EOF

    # ✅ CONFIG MIX (AVEC SSH dokodemo-door)
    cat <<EOF | sudo tee /etc/v2ray/config-mix.json > /dev/null
{
  "log": {
    "loglevel": "warning"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "policy": {
    "levels": {
      "0": {
        "statsUserUplink": true,
        "statsUserDownlink": true
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
      "port": 5401,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "0.0.0.0",
        "port": 109,
        "network": "tcp"
      },
      "tag": "ssh"
    },
    {
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
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      },
      "tag": "vless-tcp"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom"
    }
  ],
  "routing": {
    "rules": [
      {
        "inboundTag": ["api"],
        "outboundTag": "api",
        "type": "field"
      }
    ]
  }
}
EOF

# Copier config-v2only.json comme config par défaut
sudo cp /etc/v2ray/config-v2only.json /etc/v2ray/config.json

# ============================================================================
# ✅ CORRECTION : Service systemd V2Ray — Restart robuste + network-online
# ============================================================================
sudo tee /etc/systemd/system/v2ray.service >/dev/null <<'EOF'
[Unit]
Description=V2Ray Service (TCP + MIX possible)
After=network-online.target network.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/v2ray run -config /etc/v2ray/config.json
Restart=always
RestartSec=5s
StartLimitIntervalSec=0
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Ouvrir le port 5401 pour V2Ray
echo -e "${YELLOW}🔓 Ouverture du port 5401 pour V2Ray...${RESET}"
sudo iptables -I INPUT -p tcp --dport 5401 -j ACCEPT
sudo netfilter-persistent save >/dev/null 2>&1 || true

# Activer et démarrer le service
sudo systemctl daemon-reload
sudo systemctl enable v2ray.service
sudo systemctl restart v2ray.service

# Vérification rapide
sleep 2
if systemctl is-active --quiet v2ray.service && ss -tln | grep -q :5401; then
    echo -e "${GREEN}🎉 V2Ray actif sur le port 5401 !${RESET}"
    echo -e "${GREEN}✅ Redémarrage automatique activé (reboot/crash)${RESET}"
else
    echo -e "${RED}❌ Échec du démarrage V2Ray${RESET}"
    sudo journalctl -u v2ray.service -n 20 --no-pager
fi

read -p "Appuyez sur Entrée pour revenir au menu..."
