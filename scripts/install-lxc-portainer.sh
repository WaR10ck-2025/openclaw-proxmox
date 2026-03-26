#!/bin/bash
# install-lxc-portainer.sh — Portainer CE LXC 130
#
# Installiert Portainer CE (zentrale Docker-Verwaltung) als LXC.
# Portainer verwaltet alle User-App-LXCs via Portainer Agents.
#
# Architektur:
#   - Zentrale Portainer-Instanz (dieser LXC)
#   - Pro User: Portainer-Team + User-Account
#   - Pro App-LXC: Portainer Agent auf Port 9001 (via lxc_manager.py installiert)
#
# Verwendung: bash scripts/install-lxc-portainer.sh
set -e

LXC_ID=130
LXC_IP=192.168.10.130
LXC_HOSTNAME=portainer-admin
LXC_STORAGE=${PROXMOX_STORAGE:-local-lvm}
LXC_MEMORY=1024
LXC_CORES=2
PROXMOX_NODE=${PROXMOX_NODE:-pve}

TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"

echo "=== Portainer CE LXC ${LXC_ID} (${LXC_IP}) ==="

pct create ${LXC_ID} "${TEMPLATE}" \
  --hostname ${LXC_HOSTNAME} \
  --storage ${LXC_STORAGE} \
  --rootfs ${LXC_STORAGE}:8 \
  --memory ${LXC_MEMORY} \
  --cores ${LXC_CORES} \
  --net0 name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1 \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

echo "Warte auf LXC-Start..."
sleep 10

pct exec ${LXC_ID} -- bash -c "
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
"

pct exec ${LXC_ID} -- bash -c "
  docker volume create portainer_data
  docker run -d \
    --name portainer \
    --restart always \
    -p 8000:8000 \
    -p 9443:9443 \
    -p 9000:9000 \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:latest
"

echo ""
echo "✅ Portainer LXC ${LXC_ID} läuft"
echo "   Web UI: https://${LXC_IP}:9443"
echo "   HTTP:   http://${LXC_IP}:9000"
echo ""
echo "   Ersteinrichtung im Browser:"
echo "   1. Admin-Passwort setzen"
echo "   2. 'Get Started' → lokale Docker-Instanz"
echo ""
echo "   Bridge-Konfiguration (.env):"
echo "   PORTAINER_URL=http://${LXC_IP}:9000"
echo "   PORTAINER_ADMIN_USER=admin"
echo "   PORTAINER_ADMIN_PASS=<gesetztes-passwort>"
