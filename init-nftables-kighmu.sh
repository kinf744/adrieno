#!/bin/bash
# Table nftables kighmu : règles DYNAMIQUES uniquement (SSH bandwidth, UDP count)
# Les règles statiques (ports ouverts) sont dans des tables dédiées (/etc/nftables/*.nft)
set -euo pipefail

NFT=/usr/sbin/nft
TABLE="inet kighmu"

$NFT list table "$TABLE" &>/dev/null && exit 0

$NFT add table "$TABLE"
$NFT add chain "$TABLE" input  { type filter hook input priority 0\; policy accept\; }
$NFT add chain "$TABLE" output { type filter hook output priority 0\; policy accept\; }

echo "[NFT] Table $TABLE initialisée (règles dynamiques uniquement)"
