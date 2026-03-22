#!/bin/bash
# install-lxc-wine-ui.sh — LXC 202: Wine Manager React UI
# IP: 192.168.10.202 | Port: :3000

set -e

LXC_ID=202
LXC_IP="192.168.10.202"
HOSTNAME="wine-ui"
RAM=256
DISK=4
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

# Nginx-Proxy-Config für API-Backend in LXC 201
# Das Frontend-Image proxied /api → manager-api (192.168.10.201:4000)
cat > /root/wine-ui-compose-override.yml << 'EOF'
version: '3.8'
services:
  manager-ui:
    environment:
      # Nginx in wine-ui muss /api → 192.168.10.201:4000 proxyen
      API_HOST: "http://192.168.10.201:4000"
EOF

docker compose \
  -f docker-compose.yml \
  -f /opt/openclaw-proxmox/docker-compose.proxmox.yml \
  -f /root/wine-ui-compose-override.yml \
  up -d manager-ui
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:3000"
echo ""
echo "  ℹ  API-Proxy: Nginx in manager-ui leitet /api → 192.168.10.201:4000"
echo "     Falls Nginx-Config angepasst werden muss:"
echo "     pct exec 202 -- docker exec wine-manager-ui cat /etc/nginx/conf.d/default.conf"
