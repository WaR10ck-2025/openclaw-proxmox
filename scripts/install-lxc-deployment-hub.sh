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
REPO_URL="git@github.com:WaR10ck-2025/GitHub-Deployment-Connector.git"
DEPLOY_DIR="/root/docker/deployment-hub"

# Deploy Key (read-only, für dieses Repo generiert)
# Public Key hinterlegt unter: GitHub → Repo → Settings → Deploy Keys
DEPLOY_KEY_B64="LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dmJtVUFBQUFFYm05dVpRQUFBQUFBQUFBQkFBQUFNd0FBQUF0emMyZ3RaVwpReU5UVXhPUUFBQUNCekNpYkMxVmxRS3ViT3c2cnBHS2FpRGNGTGZVNTBJOGFmdE8yMmZCRytsZ0FBQUpockFpNDJhd0l1Ck5nQUFBQXR6YzJndFpXUXlOVFV4T1FBQUFDQnpDaWJDMVZsUUt1Yk93NnJwR0thaURjRkxmVTUwSThhZnRPMjJmQkcrbGcKQUFBRURQWGd2MDRCRkU5ejBINVB2UmJyVlpEWS8yMUFudE13M1YwOHZLMTZDY2duTUtKc0xWV1ZBcTVzN0RxdWtZcHFJTgp3VXQ5VG5RanhwKzA3Ylo4RWI2V0FBQUFFMjl3Wlc1amJHRjNMV1pwY25OMExXSnZiM1FCQWc9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"

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
apt-get install -y -qq curl ca-certificates git openssh-client

# Docker CE via get.docker.com (inkl. compose plugin)
curl -fsSL https://get.docker.com | sh -s -- --quiet
systemctl enable docker --quiet
systemctl start docker
command -v docker &>/dev/null || { echo "Docker-Installation fehlgeschlagen"; exit 1; }

# Deploy Key einrichten (SSH für privates Repo, idempotent)
mkdir -p /root/.ssh && chmod 700 /root/.ssh
echo '${DEPLOY_KEY_B64}' | base64 -d > /root/.ssh/openclaw-deploy-key
chmod 600 /root/.ssh/openclaw-deploy-key
grep -q 'openclaw-deploy-key' /root/.ssh/config 2>/dev/null || cat >> /root/.ssh/config << 'SSHCONF'
Host github.com
  IdentityFile /root/.ssh/openclaw-deploy-key
  StrictHostKeyChecking no
SSHCONF

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
