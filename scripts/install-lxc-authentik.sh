#!/bin/bash
# install-lxc-authentik.sh — Authentik SSO LXC 125
#
# Installiert Authentik (Identity Provider) als LXC auf Proxmox.
# Authentik stellt OIDC/LDAP-SSO bereit:
#   - Proxmox OIDC-Realm (pveum realm add)
#   - UGOS/CasaOS LDAP-Integration
#   - Admin-Dashboard OIDC-Login
#
# Verwendung: bash scripts/install-lxc-authentik.sh
set -e

LXC_ID=125
LXC_IP=192.168.10.125
LXC_HOSTNAME=authentik-sso
LXC_STORAGE=${PROXMOX_STORAGE:-local-zfs}
LXC_MEMORY=2048
LXC_CORES=2
PROXMOX_NODE=${PROXMOX_NODE:-pve}

# Debian 12 Template (ggf. anpassen)
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"

echo "=== Authentik SSO LXC ${LXC_ID} (${LXC_IP}) ==="

# LXC anlegen
pct create ${LXC_ID} "${TEMPLATE}" \
  --hostname ${LXC_HOSTNAME} \
  --storage ${LXC_STORAGE} \
  --rootfs ${LXC_STORAGE}:10 \
  --memory ${LXC_MEMORY} \
  --cores ${LXC_CORES} \
  --net0 name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1 \
  --unprivileged 1 \
  --features nesting=1 \
  --start 1 \
  --onboot 1

echo "Warte auf LXC-Start..."
sleep 10

# Docker installieren
pct exec ${LXC_ID} -- bash -c "
  apt-get update -qq
  apt-get install -y -qq curl ca-certificates
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker --now
"

# Authentik docker-compose.yml schreiben
pct exec ${LXC_ID} -- bash -c "mkdir -p /opt/authentik"

AUTHENTIK_SECRET=$(openssl rand -base64 36)
POSTGRES_PASS=$(openssl rand -base64 24)

cat > /tmp/authentik-compose.yml << EOF
services:
  postgresql:
    image: docker.io/library/postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_PASSWORD: ${POSTGRES_PASS}
      POSTGRES_USER: authentik
      POSTGRES_DB: authentik
    volumes:
      - postgres:/var/lib/postgresql/data

  redis:
    image: docker.io/library/redis:alpine
    restart: unless-stopped
    command: --save 60 1 --loglevel warning
    volumes:
      - redis:/data

  server:
    image: ghcr.io/goauthentik/server:2024.12
    restart: unless-stopped
    command: server
    environment:
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${POSTGRES_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET}
    ports:
      - "9000:9000"
      - "9443:9443"
    depends_on:
      - postgresql
      - redis

  worker:
    image: ghcr.io/goauthentik/server:2024.12
    restart: unless-stopped
    command: worker
    environment:
      AUTHENTIK_REDIS__HOST: redis
      AUTHENTIK_POSTGRESQL__HOST: postgresql
      AUTHENTIK_POSTGRESQL__USER: authentik
      AUTHENTIK_POSTGRESQL__NAME: authentik
      AUTHENTIK_POSTGRESQL__PASSWORD: ${POSTGRES_PASS}
      AUTHENTIK_SECRET_KEY: ${AUTHENTIK_SECRET}
    depends_on:
      - postgresql
      - redis

volumes:
  postgres:
  redis:
EOF

pct push ${LXC_ID} /tmp/authentik-compose.yml /opt/authentik/docker-compose.yml
rm -f /tmp/authentik-compose.yml

pct exec ${LXC_ID} -- bash -c "
  cd /opt/authentik
  docker compose up -d
"

echo ""
echo "✅ Authentik LXC ${LXC_ID} läuft"
echo "   Web UI: http://${LXC_IP}:9000/if/flow/initial-setup/"
echo "   API-Token nach Ersteinrichtung: Admin UI → System → Tokens → API-Token erstellen"
echo ""
echo "   Proxmox OIDC-Realm einrichten (nach Authentik-Setup):"
echo "   pveum realm add authentik --type openid \\"
echo "     --issuer-url http://${LXC_IP}:9000/application/o/proxmox/ \\"
echo "     --client-id proxmox --client-key <secret>"
