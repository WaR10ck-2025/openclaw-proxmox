#!/bin/bash
# install-lxc-wine-desktop.sh — LXC 200: Wine Desktop
# IP: 192.168.10.200 | Ports: :5900 (VNC) :8090 (noVNC)
#
# Besonderheiten:
# - 2048 MB RAM (Wine + VNC braucht mehr)
# - /dev/bus/usb bind-mount für USB-Geräte-Zugriff
# - device cgroup für USB (major 189)

set -e

LXC_ID=200
LXC_IP="192.168.10.200"
HOSTNAME="wine-desktop"
RAM=2048
DISK=16
CORES=2
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-zfs}"
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

# USB-Geräte cgroup (major 189 = USB Bus)
LXC_CONF="/etc/pve/lxc/${LXC_ID}.conf"
if ! grep -q "cgroup2.devices.allow: c 189" "$LXC_CONF" 2>/dev/null; then
  cat >> "$LXC_CONF" << 'EOF'

# USB-Bus Zugriff (Autocom CDP+ + andere USB-Geräte)
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
EOF
  echo "  ✓ USB cgroup-Regel gesetzt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 8
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

cd $DEPLOY_DIR

# Nur wine-desktop Service starten (kein api, kein ui — laufen in eigenen LXCs)
# Proxmox Override: usbip-server + windows-vm deaktiviert
docker compose \
  -f docker-compose.yml \
  -f /opt/openclaw-proxmox/docker-compose.proxmox.yml \
  up -d wine-desktop
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME):"
echo "     VNC (direkt):  ${LXC_IP}:5900"
echo "     noVNC Browser: http://${LXC_IP}:8090"
