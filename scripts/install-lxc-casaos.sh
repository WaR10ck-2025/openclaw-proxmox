#!/bin/bash
# install-lxc-casaos.sh — LXC 120: CasaOS Dashboard
# IP: 192.168.10.141 | Port: :80
#
# CasaOS läuft hier NUR als Dashboard/App-Store-UI.
# Keine Docker-Services — CasaOS verbindet sich via Proxmox API
# um alle LXCs als "Apps" anzuzeigen.

set -e

LXC_ID=120
LXC_IP="192.168.10.141"
HOSTNAME="casaos-dashboard"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-lvm}"

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
  echo "  ✓ LXC angelegt"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  for i in $(seq 1 30); do
    pct exec "$LXC_ID" -- test -f /etc/hostname 2>/dev/null && break
    sleep 1
  done
fi

# CasaOS installieren
cat > /tmp/lxc-${LXC_ID}-setup.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates

# CasaOS offizieller Installer (Fallback auf GitHub-URL)
curl -fsSL https://get.casaos.io | bash || \
curl -fsSL https://raw.githubusercontent.com/IceWhaleTech/CasaOS/main/get-casaos.sh | bash
command -v casaos &>/dev/null || { echo "CasaOS-Installation fehlgeschlagen"; exit 1; }
echo 'CasaOS installiert'
SETUP
pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

# casaos-lxc-bridge installieren
BRIDGE_SRC="/root/openclaw-proxmox/casaos-lxc-bridge"
if [ -d "$BRIDGE_SRC" ]; then
  cat > /tmp/lxc-${LXC_ID}-bridge-setup.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -qq git
git clone https://github.com/WaR10ck-2025/openclaw-proxmox.git /opt/openclaw-proxmox 2>/dev/null || \
  (cd /opt/openclaw-proxmox && git pull)
bash /opt/openclaw-proxmox/casaos-lxc-bridge/install.sh
SETUP
  pct push "$LXC_ID" /tmp/lxc-${LXC_ID}-bridge-setup.sh /tmp/bridge-setup.sh
  pct exec "$LXC_ID" -- bash /tmp/bridge-setup.sh
  echo "  ✓ casaos-lxc-bridge installiert (http://${LXC_IP}:8200)"
else
  echo "  ⚠  casaos-lxc-bridge Quellcode nicht gefunden — manuell installieren:"
  echo "     pct exec $LXC_ID -- bash /opt/openclaw-proxmox/casaos-lxc-bridge/install.sh"
fi

echo "  ✓ LXC $LXC_ID ($HOSTNAME): http://${LXC_IP}"
echo ""
echo "  Nächste Schritte:"
echo ""
echo "  1. LXC-App-Template erstellen (einmalig auf Proxmox-Host):"
echo "     bash /root/openclaw-proxmox/scripts/install-lxc-app-template.sh"
echo ""
echo "  2. Proxmox API-Token für casaos-lxc-bridge erstellen:"
echo "     pveum user add casaos@pve 2>/dev/null || true"
echo "     pveum acl modify / --users casaos@pve --roles PVEVMAdmin"
echo "     pveum user token add casaos@pve casaos-bridge-token --privsep=0"
echo "     # Token-UUID in CasaOS-LXC eintragen:"
echo "     pct exec $LXC_ID -- nano /opt/openclaw-proxmox/casaos-lxc-bridge/.env"
echo ""
echo "  3. Bridge-Endpunkte testen:"
echo "     curl http://${LXC_IP}:8200/health"
echo "     curl http://${LXC_IP}:8200/bridge/catalog"
echo ""
echo "  4. Erste App installieren (Beispiel n8n):"
echo "     curl -X POST 'http://${LXC_IP}:8200/bridge/install?appid=N8n'"
echo ""
echo "  5. CasaOS Dashboard → Einstellungen → Proxmox:"
echo "     Host: https://192.168.10.147:8006"
echo "     Token-ID: casaos@pve!casaos-token"
