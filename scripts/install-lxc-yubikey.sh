#!/bin/bash
# install-lxc-yubikey.sh — LXC 108: YubiKey Auth Service
# IP: 192.168.10.108 | Port: :8110
# Repo: https://github.com/WaR10ck-2025/yubikey-auth-service
#
# WICHTIG: USB-Passthrough für YubiKey muss manuell konfiguriert werden!
# Siehe: config/yubikey-usb-passthrough.md

set -e

LXC_ID=108
LXC_IP="192.168.10.108"
HOSTNAME="yubikey-auth"
RAM=256
DISK=4
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"
REPO_URL="https://github.com/WaR10ck-2025/yubikey-auth-service.git"
DEPLOY_DIR="/root/docker/yubikey"

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

# YubiKey HID cgroup-Regel zur LXC-Konfiguration hinzufügen
LXC_CONF="/etc/pve/lxc/${LXC_ID}.conf"
if ! grep -q "cgroup2.devices.allow: c 239" "$LXC_CONF" 2>/dev/null; then
  echo "  Füge YubiKey HID cgroup-Regel hinzu..."
  cat >> "$LXC_CONF" << 'EOF'

# YubiKey HID Passthrough (hidraw, major=239)
lxc.cgroup2.devices.allow: c 239:* rwm
lxc.mount.entry: /dev/yubikey dev/yubikey none bind,optional,create=file 0 0
EOF
  echo "  ✓ cgroup-Regel gesetzt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

# Udev-Regel auf HOST für persistenten /dev/yubikey Symlink
if [ ! -f /etc/udev/rules.d/99-yubikey.rules ]; then
  cat > /etc/udev/rules.d/99-yubikey.rules << 'EOF'
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1050", ATTRS{idProduct}=="0407", \
  SYMLINK+="yubikey", MODE="0660", GROUP="plugdev"
EOF
  udevadm control --reload-rules
  udevadm trigger
  echo "  ✓ Udev-Regel für /dev/yubikey angelegt"
fi

cat > /tmp/lxc-${LXC_ID}-setup.sh << SETUP
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io docker-compose-plugin git curl \
  libhidapi-dev libfido2-dev usbutils

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

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}:8110"
echo ""
echo "  ⚠  USB-Passthrough prüfen:"
echo "     pct exec 108 -- ls -la /dev/yubikey /dev/hidraw* 2>/dev/null"
echo "     → Anleitung: config/yubikey-usb-passthrough.md"
