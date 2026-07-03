#!/bin/bash
set -euo pipefail

if [ -f /etc/nftables/.initialized ]; then
    exit 0
fi

apt-get install -y nftables || { echo "❌ Impossible d'installer nftables"; exit 1; }
mkdir -p /etc/nftables

# Config de base minimale, SANS include global fragile
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f
flush ruleset
EOF

# Template systemd réutilisable pour chaque tunnel
cat > /etc/systemd/system/nftables-tunnel@.service << 'EOF'
[Unit]
Description=Charge la table nftables du tunnel %i
After=nftables.service network-online.target
Wants=network-online.target
PartOf=nftables.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables/%i.nft
ExecStop=/usr/sbin/nft delete table inet %i

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable nftables
systemctl restart nftables

touch /etc/nftables/.initialized
