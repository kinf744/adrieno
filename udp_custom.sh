#!/bin/bash
# UDP Custom v1.8 - CORRIGÉ pour HTTP Custom (comme ZIVPN)
set -euo pipefail

UDP_PORT=36712
BIN_PATH="/usr/local/bin/udp-custom"
CONFIG_FILE="/etc/udp-custom/config.json"
SERVICE_NAME="udp-custom.service"

# 1️⃣ CLEAN TOTAL
systemctl stop "$SERVICE_NAME" 2>/dev/null || true
rm -f "/etc/systemd/system/$SERVICE_NAME"
rm -rf /opt/udp-custom /var/log/udp-custom
userdel udpuser 2>/dev/null || true

# 2️⃣ BINAIRE (nom correct = udp-custom PAS udp-custom-linux-amd64)
wget -q "https://github.com/kinf744/Kighmu/releases/download/v1.0.0/udp-custom" -O "$BIN_PATH"
chmod +x "$BIN_PATH"

# 3️⃣ CONFIG (avec auth activée - liste vide au départ, remplie par menu1.sh)
mkdir -p /etc/udp-custom
cat > "$CONFIG_FILE" << 'EOF'
{
  "listen": ":36712",
  "exclude_port": [53,5300,5667,5354,5353,20000,4466],
  "timeout": 600,
  "auth": {
    "mode": "passwords",
    "config": []
  }
}
EOF

# Créer le fichier users.list vide
touch /etc/udp-custom/users.list
chmod 600 /etc/udp-custom/users.list

# 4️⃣ NFTABLES - table dédiée au service UDP Custom
/usr/local/bin/init-nftables.sh

nft delete table inet udp_custom 2>/dev/null || true

nft -f - << EOF
table inet udp_custom {
    chain input {
        type filter hook input priority 0; policy accept;
        udp dport $UDP_PORT accept
    }
}
EOF

nft list table inet udp_custom > /etc/nftables/udp_custom.nft
systemctl reload nftables 2>/dev/null || systemctl restart nftables

# 5️⃣ SYSTEMD CORRIGÉ (**CLÉ : `server` comme ZIVPN**)
cat > "/etc/systemd/system/$SERVICE_NAME" << EOF
[Unit]
Description=UDP Custom Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN_PATH server -c $CONFIG_FILE
Restart=always
RestartSec=5
LimitNOFILE=1048576
StandardOutput=journal
StandardError=journal
SyslogIdentifier=udp-custom

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# 6️⃣ TEST
sleep 3
if systemctl is-active --quiet "$SERVICE_NAME"; then
    IP=$(hostname -I | awk '{print $1}')
    echo "✅ UDP Custom OK → $IP:36712"
    echo "📱 HTTP Custom: udp://$IP:36712"
    echo "🔐 Authentification activée (liste vide - ajoutez des utilisateurs via menu1.sh)"
    ss -ulnp | grep 36712
else
    echo "❌ ÉCHEC → Logs:"
    journalctl -u udp-custom.service -n 20
fi
