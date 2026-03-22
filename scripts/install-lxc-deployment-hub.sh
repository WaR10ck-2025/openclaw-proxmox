#!/bin/bash
# install-lxc-deployment-hub.sh — LXC 170: GitHub Deployment Hub
# IP: 192.168.10.170 | Port: :8100
# Repo: https://github.com/WaR10ck-2025/GitHub-Deployment-Connector

set -e

LXC_ID=170
LXC_IP="192.168.10.170"
HOSTNAME="deployment-hub"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"
REPO_URL="https://github.com/WaR10ck-2025/GitHub-Deployment-Connector.git"
DEPLOY_DIR="/root/docker/deployment-hub"

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
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

pct exec "$LXC_ID" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
# Docker Socket-Zugriff: Deployment Hub braucht den Docker-Socket des HOST (via Proxmox API)
# Hier: Docker wird im LXC installiert, der Hub deployt per Proxmox API in andere LXCs
apt-get install -y -qq docker.io docker-compose-plugin git curl

systemctl enable docker --quiet
systemctl start docker

if [ -d '$DEPLOY_DIR/.git' ]; then
  cd '$DEPLOY_DIR' && git pull --quiet
else
  git clone '$REPO_URL' '$DEPLOY_DIR' --quiet
fi

# Proxmox-Adapter Env-Variablen konfigurieren
if [ ! -f '$DEPLOY_DIR/.env' ]; then
  cat > '$DEPLOY_DIR/.env' << 'ENVEOF'
# Deployment Hub Konfiguration
# Proxmox API (statt CasaOS Docker-Socket)
PROXMOX_HOST=192.168.10.147
PROXMOX_PORT=8006
# PROXMOX_TOKEN_ID=casaos@pve!casaos-token
# PROXMOX_TOKEN_SECRET=<secret>

# Service-IPs (kein Docker bridge mehr)
WINE_API_HOST=192.168.10.201
WINE_API_PORT=4000
ENVEOF
  echo 'HINWEIS: .env angelegt — Proxmox API-Token eintragen!'
fi

bash '$DEPLOY_DIR/scripts/server/install.sh'
"

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:8100"
echo "  ⚠  Proxmox API-Token in .env setzen: pct exec 170 -- nano $DEPLOY_DIR/.env"
