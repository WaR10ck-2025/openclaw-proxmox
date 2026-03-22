#!/bin/bash
# install-lxc-usbipd.sh — LXC 210: usbipd nativ (ohne Docker)
# IP: 192.168.10.210 | Port: :3240
#
# Teilt den Autocom CDP+ USB-Adapter (FTDI 0403:d6da) über das Netzwerk.
# Clients (z.B. Windows mit usbipd-win) verbinden sich direkt via TCP.
#
# WICHTIG: LXC 210 muss privileged=1 laufen (modprobe usbip-core/usbip-host)!

set -e

LXC_ID=210
LXC_IP="192.168.10.210"
HOSTNAME="usbipd"
RAM=128
DISK=2
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"

echo "► LXC $LXC_ID ($HOSTNAME) — $LXC_IP..."

if ! pct status "$LXC_ID" &>/dev/null; then
  # PRIVILEGED (required für modprobe + usbip-host Kernel-Modul)
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=192.168.10.1" \
    --nameserver "1.1.1.1" \
    --features "nesting=0" \
    --unprivileged 0 \
    --start 0
  echo "  ✓ LXC angelegt (privileged — für modprobe nötig)"
fi

# USB-Bus + Kernel-Module cgroup
LXC_CONF="/etc/pve/lxc/${LXC_ID}.conf"
if ! grep -q "usbip" "$LXC_CONF" 2>/dev/null; then
  cat >> "$LXC_CONF" << 'EOF'

# USB/IP Passthrough
lxc.cgroup2.devices.allow: c 189:* rwm
lxc.mount.entry: /dev/bus/usb dev/bus/usb none bind,optional,create=dir 0 0
lxc.mount.entry: /lib/modules /lib/modules none bind,ro,optional 0 0
EOF
  echo "  ✓ USB + Kernel-Module cgroup-Regeln gesetzt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  sleep 5
fi

# usbipd installieren und als systemd-Service einrichten
cat > /tmp/lxc-${LXC_ID}-setup.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq usbip hwdata kmod

# Kernel-Module laden
modprobe usbip_core 2>/dev/null || true
modprobe usbip_host 2>/dev/null || true

# Module beim Boot laden
echo 'usbip_core' >> /etc/modules 2>/dev/null || true
echo 'usbip_host' >> /etc/modules 2>/dev/null || true

# systemd-Service von Repo-Konfiguration
cat > /etc/systemd/system/usbipd.service << 'SERVICEEOF'
[Unit]
Description=USB/IP Server — Autocom CDP+ (FTDI 0403:d6da)
After=network.target

[Service]
Type=forking
ExecStartPre=/sbin/modprobe usbip_core
ExecStartPre=/sbin/modprobe usbip_host
ExecStart=/usr/sbin/usbipd --daemon
ExecStartPost=/bin/bash -c "sleep 1 && BUSID=$(usbip list -l 2>/dev/null | grep '0403:d6da' | awk '{print $1}' | tr -d ':') && [ -n \"$BUSID\" ] && usbip bind --busid=\"$BUSID\" || echo 'Autocom CDP+ nicht gefunden'"
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
SERVICEEOF

systemctl daemon-reload
systemctl enable usbipd
systemctl start usbipd 2>/dev/null || echo 'usbipd start fehlgeschlagen (USB-Gerät nicht angeschlossen?)'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo "  ✓ LXC $LXC_ID ($HOSTNAME): usbipd auf ${LXC_IP}:3240"
echo ""
echo "  USB-Geräte prüfen:"
echo "     pct exec 210 -- usbip list -l"
echo "     pct exec 210 -- systemctl status usbipd"
echo ""
echo "  Windows-Client verbinden:"
echo "     usbipd attach --remote ${LXC_IP} --busid <busid>"
