#!/bin/bash
# install-lxc-app-template.sh — Docker-in-LXC Basis-Template für CasaOS App-Store Apps
#
# Erstellt ein LXC-Template (Debian 12 + Docker CE) das als Clone-Basis
# für alle dynamisch via casaos-lxc-bridge installierten Apps dient.
#
# Verwendung:
#   bash install-lxc-app-template.sh
#
# Voraussetzung: Proxmox VE 8.x, Debian 12 Template bereits heruntergeladen
#   pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst

set -e

TEMPLATE_ID=9000
HOSTNAME="casaos-app-template"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"

echo "► LXC Template $TEMPLATE_ID ($HOSTNAME) erstellen..."

# Vorhandenes Template entfernen (idempotent)
if pct status "$TEMPLATE_ID" &>/dev/null; then
  pct stop "$TEMPLATE_ID" 2>/dev/null || true
  pct destroy "$TEMPLATE_ID" --purge 2>/dev/null || true
  echo "  ✓ Altes Template entfernt"
fi

# LXC erstellen
pct create "$TEMPLATE_ID" "$TEMPLATE" \
  --hostname "$HOSTNAME" \
  --memory "$RAM" \
  --cores "$CORES" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=vmbr0,ip=dhcp" \
  --nameserver "1.1.1.1" \
  --features "nesting=1,keyctl=1" \
  --unprivileged 1 \
  --start 0
echo "  ✓ LXC angelegt"

pct start "$TEMPLATE_ID"
echo "  ✓ LXC gestartet — warte auf Boot..."
for i in $(seq 1 30); do
  pct exec "$TEMPLATE_ID" -- test -f /etc/hostname 2>/dev/null && break
  sleep 1
done

# Docker CE installieren
cat > /tmp/lxc-${TEMPLATE_ID}-setup.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  ca-certificates curl gnupg lsb-release \
  docker.io docker-compose-plugin

# Docker-Dienst aktivieren
systemctl enable docker
systemctl start docker

# Smoke-Test
docker run --rm hello-world >/dev/null 2>&1 && echo 'Docker OK'
docker compose version
SETUP
pct push "$TEMPLATE_ID" /tmp/lxc-${TEMPLATE_ID}-setup.sh /tmp/setup.sh
pct exec "$TEMPLATE_ID" -- bash /tmp/setup.sh
echo "  ✓ Docker CE installiert"

# Template konvertieren
pct stop "$TEMPLATE_ID"
echo "  ✓ Template gestoppt"

# Als Proxmox-Template markieren
pct set "$TEMPLATE_ID" --template 1
echo ""
echo "  ✓ LXC $TEMPLATE_ID als Template gespeichert"
echo ""
echo "  Verwendung durch casaos-lxc-bridge:"
echo "  pct clone $TEMPLATE_ID <NEW_ID> --hostname <name> --full"
echo "  pct set <NEW_ID> --net0 name=eth0,bridge=vmbr0,ip=<IP>/24,gw=192.168.10.1"
echo "  pct start <NEW_ID>"
