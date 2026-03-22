#!/bin/bash
# install-lxc-pionex.sh — LXC 102: Pionex MCP Server
# IP: 192.168.10.102 | Port: :8000
# Repo: https://github.com/WaR10ck-2025/Pionex-MCP-Server

set -e

LXC_ID=102
LXC_IP="192.168.10.102"
HOSTNAME="pionex-mcp-server"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-zfs}"
REPO_URL="https://github.com/WaR10ck-2025/Pionex-MCP-Server.git"
DEPLOY_DIR="/root/docker/pionex"

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
apt-get install -y -qq git curl\ncurl -fsSL https://get.docker.com | sh

systemctl enable docker --quiet
systemctl start docker

if [ -d '$DEPLOY_DIR/.git' ]; then
  cd '$DEPLOY_DIR' && git pull --quiet
else
  git clone '$REPO_URL' '$DEPLOY_DIR' --quiet
fi

bash '$DEPLOY_DIR/scripts/server/install.sh'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:8000"
