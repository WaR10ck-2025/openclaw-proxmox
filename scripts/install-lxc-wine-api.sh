#!/bin/bash
# install-lxc-wine-api.sh — LXC 201: Wine Manager FastAPI Backend
# IP: 192.168.10.201 | Port: :4000

set -e

LXC_ID=201
LXC_IP="192.168.10.201"
HOSTNAME="wine-api"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"
REPO_URL="https://github.com/WaR10ck-2025/wine-docker-manager.git"
DEPLOY_DIR="/root/docker/wine-manager"

echo "► LXC $LXC_ID ($HOSTNAME) — $LXC_IP..."

if ! pct status "$LXC_ID" &>/dev/null; then
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1" \
    --nameserver "1.1.1.1" \
    --features "nesting=1" \
    --unprivileged 1 \
    --start 0
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

cat > /tmp/lxc-${LXC_ID}-setup.sh << SETUP
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-plugin git curl

systemctl enable docker --quiet
systemctl start docker

if [ -d '$DEPLOY_DIR/.git' ]; then
  cd '$DEPLOY_DIR' && git pull --quiet
else
  git clone '$REPO_URL' '$DEPLOY_DIR' --quiet
fi

cd $DEPLOY_DIR

# manager-api mit Proxmox-spezifischen Env-Vars starten
# Wine-Container läuft in LXC 200 (nicht per Container-Name erreichbar)
# docker exec auf wine-desktop funktioniert über LXC 200 lokal, NICHT von hier aus
# → manager-api muss in LXC 200 laufen oder via SSH/API kommunizieren
# EMPFEHLUNG: manager-api und wine-desktop in LXC 200 zusammen deployen
# (wine-api LXC ist dann nur für externe API ohne docker-exec-Zugriff nötig)

cat > /root/wine-api-compose-override.yml << 'EOF'
version: '3.8'
services:
  manager-api:
    environment:
      WINE_CONTAINER: wine-desktop
      USBIP_REMOTE_HOST: "192.168.10.210"
      NANOPI_ETH_HOST: "192.168.10.193"
      OBD_MONITOR_HOST: "192.168.10.194"
      OBD_MONITOR_PORT: "8765"
      WICAN_HOST: "192.168.10.200"
      WICAN_PORT: "3333"
      VGATE_HOST: "192.168.10.201"
      VGATE_PORT: "35000"
EOF

docker compose \
  -f docker-compose.yml \
  -f /opt/openclaw-proxmox/docker-compose.proxmox.yml \
  -f /root/wine-api-compose-override.yml \
  up -d manager-api
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:4000"
echo ""
echo "  ℹ  Hinweis: wine-api benötigt Zugriff auf wine-desktop (docker exec)."
echo "     Für vollständige Funktionalität: beide Services in LXC 200 deployen."
echo "     Siehe MIGRATION.md → Schritt 3."
