#!/bin/bash
# install-lxc-casaos.sh — LXC 120: CasaOS Dashboard
# IP: 192.168.10.141 | Port: :80
#
# CasaOS läuft hier NUR als Dashboard/App-Store-UI.
# Keine Docker-Services — CasaOS verbindet sich via Proxmox API
# um alle LXCs als "Apps" anzuzeigen.

set -e

LXC_ID=120
LXC_IP="192.168.10.141"
HOSTNAME="casaos-dashboard"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"

echo "► LXC $LXC_ID ($HOSTNAME) — $LXC_IP..."

if ! pct status "$LXC_ID" &>/dev/null; then
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1" \
    --nameserver "192.168.10.1" \
    --features "nesting=1" \
    --unprivileged 1 \
    --start 0
  echo "  ✓ LXC angelegt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

# CasaOS installieren
pct exec "$LXC_ID" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates

# CasaOS offizieller Installer
curl -fsSL https://get.casaos.io | bash 2>/dev/null || \
curl -fsSL https://raw.githubusercontent.com/IceWhaleTech/CasaOS/main/get-casaos.sh | bash
echo 'CasaOS installiert'
"

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}"
echo ""
echo "  Nächste Schritte für CasaOS → Proxmox-Integration:"
echo "  1. Auf Proxmox-Host: Proxmox API-Token erstellen"
echo "     pveum user add casaos@pve && pveum acl modify / --users casaos@pve --roles PVEAuditor"
echo "     pveum user token add casaos@pve casaos-token --privsep=0"
echo "  2. In CasaOS Web-UI: Einstellungen → Proxmox"
echo "     Host: https://192.168.10.147:8006"
echo "     Token-ID: casaos@pve!casaos-token"
