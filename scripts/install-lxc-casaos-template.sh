#!/bin/bash
# install-lxc-casaos-template.sh — LXC 9001: CasaOS User-Template
#
# Erstellt ein privilegiertes LXC mit:
#   - Docker + Docker Compose
#   - CasaOS Dashboard
#   - Samba (SMB-Shares: /DATA/AppData + /DATA/Gallery)
#
# Dieses LXC ist die Clone-Quelle für alle User-CasaOS-Instanzen.
# WICHTIG: Privilegiert (unprivileged=0) — nötig für ZFS-Bindmounts.
#
# Ausführen auf dem Proxmox-Host als root:
#   bash scripts/install-lxc-casaos-template.sh

set -e

LXC_ID=9001
HOSTNAME="casaos-user-template"
RAM=2048
DISK=20
CORES=2
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-zfs}"

# Temporäre IP für Setup (wird beim Clone überschrieben)
SETUP_IP="192.168.10.251"
GATEWAY="192.168.10.1"

echo "► LXC $LXC_ID ($HOSTNAME) — CasaOS User-Template..."

if pct status "$LXC_ID" &>/dev/null; then
  echo "  ► LXC $LXC_ID existiert bereits — überspringe Anlage"
else
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${SETUP_IP}/24,gw=${GATEWAY}" \
    --nameserver "1.1.1.1 8.8.8.8" \
    --features "nesting=1,keyctl=1" \
    --unprivileged 0 \
    --start 0
  echo "  ✓ LXC $LXC_ID angelegt (privilegiert)"
fi

if ! pct status "$LXC_ID" | grep -q "running"; then
  pct start "$LXC_ID"
  echo -n "  Warte auf LXC-Start..."
  for i in $(seq 1 60); do
    pct exec "$LXC_ID" -- test -f /etc/hostname 2>/dev/null && break
    echo -n "."
    sleep 1
  done
  echo " OK"
fi

# ─── Setup-Script erstellen + übertragen ────────────────────────────────────
cat > /tmp/casaos-template-setup.sh << 'SETUP'
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "── System-Update ────────────────────────────────"
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  curl ca-certificates gnupg lsb-release \
  openssh-server samba samba-common-bin \
  python3 python3-pip git

# ── Docker installieren ───────────────────────────────────────────────────────
if ! command -v docker &>/dev/null; then
  echo "── Docker installieren ──────────────────────────"
  curl -fsSL https://get.docker.com | sh
  systemctl enable docker
  systemctl start docker
  echo "  ✓ Docker installiert: $(docker --version)"
else
  echo "  ✓ Docker bereits vorhanden: $(docker --version)"
fi

# ── CasaOS installieren ───────────────────────────────────────────────────────
if ! command -v casaos &>/dev/null; then
  echo "── CasaOS installieren ──────────────────────────"
  curl -fsSL https://get.casaos.io | bash || \
  curl -fsSL https://raw.githubusercontent.com/IceWhaleTech/CasaOS/main/get-casaos.sh | bash
  command -v casaos &>/dev/null || { echo "FEHLER: CasaOS-Installation fehlgeschlagen"; exit 1; }
  echo "  ✓ CasaOS installiert"
else
  echo "  ✓ CasaOS bereits vorhanden"
fi

# ── Verzeichnisse anlegen ─────────────────────────────────────────────────────
mkdir -p /DATA/AppData /DATA/Gallery /opt/casaos-bridge

# ── Samba konfigurieren ───────────────────────────────────────────────────────
echo "── Samba konfigurieren ──────────────────────────"

# System-User für Samba anlegen (kein Login-Shell)
useradd -M -s /sbin/nologin casaos 2>/dev/null || true

# Samba-Konfiguration
cat > /etc/samba/smb.conf << 'SMBCONF'
[global]
   workgroup = OPENCLAW
   server string = CasaOS User Storage
   security = user
   map to guest = bad user
   dns proxy = no
   server min protocol = SMB2

[files]
   path = /DATA/Gallery
   browsable = yes
   writable = yes
   guest ok = no
   valid users = casaos
   create mask = 0664
   directory mask = 0775
   force user = root

[appdata]
   path = /DATA/AppData
   browsable = yes
   writable = yes
   guest ok = no
   valid users = casaos
   create mask = 0664
   directory mask = 0775
   force user = root
SMBCONF

# Samba-Services aktivieren (Passwort wird beim User-Provisioning gesetzt)
systemctl enable smbd nmbd
systemctl start smbd nmbd || true
echo "  ✓ Samba konfiguriert (Passwort wird bei User-Anlage gesetzt)"

# ── SSH für pct exec ──────────────────────────────────────────────────────────
systemctl enable ssh
systemctl start ssh || true

echo ""
echo "══════════════════════════════════════════════════"
echo "  CasaOS User-Template (LXC 9001) — FERTIG"
echo "  Docker:  $(docker --version)"
echo "  CasaOS:  $(casaos --version 2>/dev/null || echo 'installiert')"
echo "  Samba:   $(smbd --version)"
echo "══════════════════════════════════════════════════"
SETUP

pct push "$LXC_ID" /tmp/casaos-template-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo ""
echo "✓ LXC $LXC_ID (casaos-user-template) bereit als Clone-Quelle"
echo "  Nächster Schritt: Template konvertieren (optional):"
echo "    pct template $LXC_ID"
echo "  Oder direkt als laufendes LXC als Clone-Quelle nutzen (Proxmox unterstützt beides)"
