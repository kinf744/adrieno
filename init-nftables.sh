#!/bin/bash
set -euo pipefail

# Init unique du système nftables — à lancer une seule fois sur le VPS
if [ -f /etc/nftables/.initialized ]; then
    exit 0
fi

apt install -y nftables
mkdir -p /etc/nftables

if [ ! -s /etc/nftables.conf ]; then
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

include "/etc/nftables/*.nft"
EOF
else
    grep -q 'include "/etc/nftables/\*.nft"' /etc/nftables.conf || \
    echo 'include "/etc/nftables/*.nft"' >> /etc/nftables.conf
fi

systemctl enable nftables
systemctl restart nftables

touch /etc/nftables/.initialized
