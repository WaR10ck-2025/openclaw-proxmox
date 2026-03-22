#!/bin/bash
# install-lxc-nextcloud.sh — LXC 109: Nextcloud
# IP: 192.168.10.109 | Port: :80
#
# Stack: Docker-in-LXC — Nextcloud 29-apache + MariaDB 11
# Daten: /opt/nextcloud/{data,db} (persistent im LXC)
# CasaOS-Registrierung: automatisch am Ende via /v2/apps

set -e

LXC_ID=109
LXC_IP="192.168.10.109"
HOSTNAME="nextcloud"
RAM=2048
DISK=32
CORES=2
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"
CASAOS_API="http://192.168.10.141/v2/apps"

echo "► LXC $LXC_ID ($HOSTNAME) — $LXC_IP..."

# ── LXC anlegen (idempotent) ─────────────────────────────────────────────
if ! pct status "$LXC_ID" &>/dev/null; then
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1" \
    --nameserver "1.1.1.1" \
    --features "nesting=1,keyctl=1" \
    --unprivileged 1 \
    --start 0
  echo "  ✓ LXC angelegt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  echo "  ✓ LXC gestartet — warte auf Boot..."
  for i in $(seq 1 30); do
    pct exec "$LXC_ID" -- test -f /etc/hostname 2>/dev/null && break
    sleep 1
  done
fi

# ── Docker CE installieren ───────────────────────────────────────────────
cat > /tmp/lxc-${LXC_ID}-docker.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

# Prüfen ob Docker bereits installiert
if command -v docker &>/dev/null; then
  echo '  Docker bereits vorhanden'
  exit 0
fi

apt-get update -qq
apt-get install -y -qq ca-certificates curl docker.io docker-compose-plugin
systemctl enable docker
systemctl start docker
docker --version
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-docker.sh /tmp/docker.sh
pct exec "$LXC_ID" -- bash /tmp/docker.sh
echo "  ✓ Docker CE bereit"

# ── Passwörter generieren (einmalig) ────────────────────────────────────
cat > /tmp/lxc-${LXC_ID}-passwords.sh << 'SETUP'
#!/bin/bash
set -e
ENV_FILE=/opt/nextcloud/.env
mkdir -p /opt/nextcloud/{data,db}

if [ -f "$ENV_FILE" ]; then
  echo '  .env bereits vorhanden — Passwörter unverändert'
  exit 0
fi

DB_ROOT_PASSWORD=$(openssl rand -hex 16)
DB_PASSWORD=$(openssl rand -hex 16)
ADMIN_PASSWORD=$(openssl rand -hex 12)

cat > "$ENV_FILE" << EOF
DB_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
DB_PASSWORD=${DB_PASSWORD}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
EOF
chmod 600 "$ENV_FILE"
echo '  ✓ Passwörter generiert + in /opt/nextcloud/.env gespeichert'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-passwords.sh /tmp/passwords.sh
pct exec "$LXC_ID" -- bash /tmp/passwords.sh

# ── docker-compose.yml schreiben ────────────────────────────────────────
cat > /tmp/lxc-${LXC_ID}-compose.sh << 'SETUP'
#!/bin/bash
cat > /opt/nextcloud/docker-compose.yml << 'COMPOSE_EOF'
services:
  db:
    image: mariadb:11
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${DB_ROOT_PASSWORD}
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${DB_PASSWORD}
    volumes:
      - /opt/nextcloud/db:/var/lib/mysql
    healthcheck:
      test: ["CMD", "healthcheck.sh", "--connect", "--innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 5

  nextcloud:
    image: nextcloud:29-apache
    restart: unless-stopped
    ports:
      - "80:80"
    depends_on:
      db:
        condition: service_healthy
    environment:
      MYSQL_HOST: db
      MYSQL_DATABASE: nextcloud
      MYSQL_USER: nextcloud
      MYSQL_PASSWORD: ${DB_PASSWORD}
      NEXTCLOUD_ADMIN_USER: admin
      NEXTCLOUD_ADMIN_PASSWORD: ${ADMIN_PASSWORD}
      NEXTCLOUD_TRUSTED_DOMAINS: 192.168.10.109
      PHP_MEMORY_LIMIT: 512M
      PHP_UPLOAD_LIMIT: 10G
    volumes:
      - /opt/nextcloud/data:/var/www/html
COMPOSE_EOF
echo '  ✓ docker-compose.yml geschrieben'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-compose.sh /tmp/compose.sh
pct exec "$LXC_ID" -- bash /tmp/compose.sh

# ── Nextcloud starten ────────────────────────────────────────────────────
cat > /tmp/lxc-${LXC_ID}-start.sh << 'SETUP'
#!/bin/bash
cd /opt/nextcloud
docker compose --env-file .env up -d
echo '  ✓ Nextcloud + MariaDB gestartet'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-start.sh /tmp/start.sh
pct exec "$LXC_ID" -- bash /tmp/start.sh
echo "  ✓ Container laufen — warte auf Nextcloud (kann 2-3 Min dauern)..."

# Warten bis HTTP-Response (max 180s)
for i in $(seq 1 36); do
  STATUS=$(pct exec "$LXC_ID" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null || echo 000")
  if [ "$STATUS" = "200" ] || [ "$STATUS" = "302" ]; then
    echo "  ✓ Nextcloud antwortet (HTTP $STATUS)"
    break
  fi
  echo "  … warte ($((i * 5))s) — HTTP $STATUS"
  sleep 5
done

# ── Admin-Passwort anzeigen ──────────────────────────────────────────────
ADMIN_PW=$(pct exec "$LXC_ID" -- bash -c "grep ADMIN_PASSWORD /opt/nextcloud/.env | cut -d= -f2")

# ── CasaOS Dashboard registrieren ────────────────────────────────────────
echo "  → Nextcloud in CasaOS Dashboard registrieren..."

COMPOSE_WITH_XCASAOS=$(cat << 'XCASAOS_EOF'
services:
  nextcloud:
    image: nextcloud:29-apache
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /opt/nextcloud/data:/var/www/html

x-casaos:
  architectures: [amd64, arm64]
  main: nextcloud
  category: Cloud
  description:
    en_US: "Nextcloud — self-hosted productivity platform for file sync, sharing, and collaboration"
  icon: "https://cdn.jsdelivr.net/gh/IceWhaleTech/CasaOS-AppStore@main/Apps/Nextcloud/icon.png"
  tagline:
    en_US: "Your data, your rules"
  title:
    en_US: "Nextcloud"
  port_map: "192.168.10.109:80"
  developer: "Nextcloud GmbH"
  author: "OpenClaw"
XCASAOS_EOF
)

# Registrierung via CasaOS API (Fehler ist nicht fatal — CasaOS muss laufen)
PAYLOAD=$(printf '{"compose_app": %s}' "$(echo "$COMPOSE_WITH_XCASAOS" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')")
curl -s -X POST "$CASAOS_API" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  -o /dev/null -w "  CasaOS API: HTTP %{http_code}\n" \
  || echo "  ⚠  CasaOS-Registrierung übersprungen (CasaOS erreichbar?)"

# ── Zusammenfassung ──────────────────────────────────────────────────────
echo ""
echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}"
echo ""
echo "  ╔══════════════════════════════════════════════════╗"
echo "  ║            Nextcloud Zugangsdaten                ║"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  URL:       http://192.168.10.109                ║"
echo "  ║  Benutzer:  admin                                ║"
echo "  ║  Passwort:  $ADMIN_PW"
echo "  ╠══════════════════════════════════════════════════╣"
echo "  ║  Passwörter in LXC: /opt/nextcloud/.env          ║"
echo "  ╚══════════════════════════════════════════════════╝"
echo ""
echo "  Nginx Proxy Manager → Nextcloud:"
echo "    Forward Hostname: 192.168.10.109  Port: 80"
