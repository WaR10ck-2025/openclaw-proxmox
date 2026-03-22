#!/bin/bash
# install-lxc-n8n.sh — LXC 104: n8n Workflow Automation
# IP: 192.168.10.104 | Port: :5678

set -e

LXC_ID=104
LXC_IP="192.168.10.104"
HOSTNAME="n8n"
RAM=1024
DISK=16
CORES=2
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"
DEPLOY_DIR="/root/docker/n8n"

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
apt-get install -y -qq docker.io docker-compose-plugin curl

systemctl enable docker --quiet
systemctl start docker

mkdir -p '$DEPLOY_DIR'
cat > '$DEPLOY_DIR/docker-compose.yml' << 'EOF'
version: '3.8'
services:
  n8n:
    image: n8nio/n8n:latest
    container_name: n8n
    restart: unless-stopped
    ports:
      - '5678:5678'
    environment:
      - N8N_HOST=0.0.0.0
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - WEBHOOK_URL=http://192.168.10.104:5678/
      - GENERIC_TIMEZONE=Europe/Berlin
      - TZ=Europe/Berlin
      # .env Datei für Secrets: N8N_ENCRYPTION_KEY, N8N_BASIC_AUTH_PASSWORD etc.
    env_file:
      - .env
    volumes:
      - n8n_data:/home/node/.n8n
volumes:
  n8n_data:
EOF

# .env falls nicht vorhanden anlegen
if [ ! -f '$DEPLOY_DIR/.env' ]; then
  cat > '$DEPLOY_DIR/.env' << 'ENVEOF'
# n8n Konfiguration — SECRETS HIER EINTRAGEN
N8N_ENCRYPTION_KEY=change-me-please
# N8N_BASIC_AUTH_ACTIVE=true
# N8N_BASIC_AUTH_USER=admin
# N8N_BASIC_AUTH_PASSWORD=changeme
ENVEOF
  echo 'HINWEIS: $DEPLOY_DIR/.env angelegt — N8N_ENCRYPTION_KEY setzen!'
fi

cd $DEPLOY_DIR
docker compose pull --quiet 2>/dev/null || true
docker compose up -d
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:5678"
echo "  ⚠  .env in LXC: pct exec 104 -- nano /root/docker/n8n/.env"
