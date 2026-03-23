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

# ── OpenClaw App-Store vorregistrieren ───────────────────────────────────────
echo "── OpenClaw App-Store vorregistrieren ───────────────"
BRIDGE_STORE_URL="${BRIDGE_URL:-http://192.168.10.141:8200}/casaos-store.zip"

# Sicherstellen dass [server]-Sektion existiert
grep -q '^\[server\]' /etc/casaos/app-management.conf 2>/dev/null || \
  echo "[server]" >> /etc/casaos/app-management.conf

# Idempotent eintragen (nur wenn nicht schon vorhanden)
grep -q "casaos-store.zip" /etc/casaos/app-management.conf 2>/dev/null || \
  sed -i "/^\[server\]/a appstore = ${BRIDGE_STORE_URL}" /etc/casaos/app-management.conf

# CasaOS App-Management neu starten damit Store-Download startet
systemctl restart casaos-app-management 2>/dev/null || true
sleep 5
echo "  ✓ OpenClaw Store vorregistriert: ${BRIDGE_STORE_URL}"

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

# ── Host-Blockgeräte vor CasaOS verbergen ────────────────────────────────────
# Privilegierte LXC-Container erhalten Geräteknoten für alle Host-Laufwerke.
# Diese udev-Regel + Service verhindert, dass CasaOS sie im Storage-Manager anzeigt.
echo "── Hide-Host-Disks konfigurieren ────────────────"

# lsblk-Wrapper: filtert Host-Blockgeräte aus casaos-local-storage's Sicht.
# lsblk liest /sys/block/ — ohne Wrapper wären Drives trotz fehlender /dev-Nodes sichtbar.
cat > /usr/bin/lsblk-real << 'REALEND'
#!/bin/bash
exec /usr/bin/lsblk.real "$@"
REALEND
# Original sichern (idempotent)
[ -f /usr/bin/lsblk.real ] || cp /usr/bin/lsblk /usr/bin/lsblk.real

cat > /usr/bin/lsblk << 'PYEND'
#!/usr/bin/env python3
"""lsblk wrapper: filtert Host-Blockgeraete (sd*, nvme*, hd*, vd*) aus Output.
Verhindert dass casaos-local-storage physische Proxmox-Laufwerke erkennt."""
import subprocess, json, sys, re

HIDDEN = ('sd', 'nvme', 'hd', 'vd')
TREE_RE = re.compile(r'^[|`\- ]*(\S+)')

result = subprocess.run(['/usr/bin/lsblk.real'] + sys.argv[1:],
                        capture_output=True, text=True)

if '-J' in sys.argv or '--json' in sys.argv:
    try:
        data = json.loads(result.stdout)
        data['blockdevices'] = [
            d for d in data.get('blockdevices', [])
            if not any(d.get('name', '').startswith(p) for p in HIDDEN)
        ]
        print(json.dumps(data))
    except Exception:
        print(result.stdout, end='')
else:
    for line in result.stdout.splitlines():
        m = TREE_RE.match(line)
        if m and any(m.group(1).startswith(p) for p in HIDDEN):
            continue
        print(line)

if result.stderr:
    print(result.stderr, end='', file=sys.stderr)
sys.exit(result.returncode)
PYEND
chmod +x /usr/bin/lsblk
echo "  ✓ lsblk-Wrapper installiert (filtert sd/nvme/hd/vd)"

cat > /etc/udev/rules.d/99-lxc-hide-host-disks.rules << 'UDEV'
# LXC: Host-Blockgeräte (SATA/NVMe) sofort nach Erstellung entfernen,
# damit casaos-local-storage sie nicht als "Found a new drive" meldet.
SUBSYSTEM=="block", KERNEL=="sd[a-z]",       OPTIONS+="nowatch", RUN+="/bin/rm -f /dev/%k"
SUBSYSTEM=="block", KERNEL=="sd[a-z][0-9]*", OPTIONS+="nowatch", RUN+="/bin/rm -f /dev/%k"
SUBSYSTEM=="block", KERNEL=="nvme[0-9]*",    OPTIONS+="nowatch", RUN+="/bin/rm -f /dev/%k"
SUBSYSTEM=="block", KERNEL=="hd[a-z]*",      OPTIONS+="nowatch", RUN+="/bin/rm -f /dev/%k"
SUBSYSTEM=="block", KERNEL=="vd[a-z]*",      OPTIONS+="nowatch", RUN+="/bin/rm -f /dev/%k"
UDEV

cat > /etc/systemd/system/casaos-hide-host-disks.service << 'SVC'
[Unit]
Description=Hide host physical block devices from CasaOS LXC
DefaultDependencies=no
Before=casaos-local-storage.service
After=udev.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'rm -f /dev/sd[a-z] /dev/sd[a-z][0-9]* /dev/nvme* /dev/hd[a-z]* /dev/vd[a-z]*'

[Install]
WantedBy=sysinit.target
SVC

systemctl enable casaos-hide-host-disks.service
echo "  ✓ udev-Regeln + hide-disks.service aktiviert"

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
