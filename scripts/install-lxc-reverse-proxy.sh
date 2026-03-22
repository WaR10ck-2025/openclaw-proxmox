#!/bin/bash
# install-lxc-reverse-proxy.sh — LXC 110: Nginx Proxy Manager
# IP: 192.168.10.140 | Ports: :80 :443 :81 (Admin-UI)

set -e

LXC_ID=110
LXC_IP="192.168.10.140"
HOSTNAME="reverse-proxy"
RAM=256
DISK=4
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="local-lvm"

echo "► LXC $LXC_ID ($HOSTNAME) — $LXC_IP..."

# Idempotent: LXC nur anlegen wenn noch nicht vorhanden
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

# Starten falls nicht läuft
if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

# Nginx Proxy Manager installieren
pct exec "$LXC_ID" -- bash -c "
set -e
export DEBIAN_FRONTEND=noninteractive

# Basis-Pakete
apt-get update -qq
apt-get install -y -qq curl ca-certificates gnupg2 lsb-release

# Docker installieren
curl -fsSL https://get.docker.com | sh -s -- --quiet
systemctl enable docker --quiet
command -v docker &>/dev/null || { echo "Docker-Installation fehlgeschlagen"; exit 1; }

# Nginx Proxy Manager deployen
mkdir -p /opt/nginx-proxy-manager
cat > /opt/nginx-proxy-manager/docker-compose.yml << 'EOF'
version: '3.8'
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    ports:
      - '80:80'
      - '443:443'
      - '81:81'
    volumes:
      - npm-data:/data
      - npm-letsencrypt:/etc/letsencrypt
volumes:
  npm-data:
  npm-letsencrypt:
EOF

cd /opt/nginx-proxy-manager
docker compose pull --quiet 2>/dev/null || docker-compose pull --quiet 2>/dev/null || true
docker compose up -d 2>/dev/null || docker-compose up -d 2>/dev/null
echo 'Nginx Proxy Manager gestartet'
"

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:81  (admin@example.com / changeme)"
