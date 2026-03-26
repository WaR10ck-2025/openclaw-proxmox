#!/bin/bash
# install-lxc-ugos-template.sh — UGOS Template-VM 9002
#
# Erstellt eine Proxmox KVM-VM als UGOS-Template (ID 9002).
# UGOS installiert sich von einem Firmware-Paket aus auf eine laufende Debian-VM.
#
# Voraussetzungen:
#   - UGOS-Firmware-Paket lokal vorhanden (z.B. release_*-intel_amd64*.img)
#   - Debian 12 netinstall-ISO verfügbar ODER vorhandenes Debian-Template (DEBIAN_CLONE_ID)
#   - Proxmox root SSH-Zugriff
#
# Verwendung:
#   UGOS_IMG="/path/to/release_20260128-firmware_image-1.13.1.105-intel_amd64_6.12.30+.img" \
#   bash scripts/install-lxc-ugos-template.sh
#
# Schritte:
#   1. Debian 12 VM anlegen (VM 9002, 32GB Disk, 2GB RAM)
#   2. Firmware-Paket via SCP in die VM übertragen
#   3. ugospro-upgrade Installer ausführen → UGOS überschreibt Debian
#   4. VM neu starten → UGOS-Wizard abschließen
#   5. VM stoppen + als Proxmox-Template einfrieren
set -e

PROXMOX_HOST=${PROXMOX_HOST:-192.168.10.147}
PROXMOX_NODE=${PROXMOX_NODE:-pve}
VM_ID=9002
VM_NAME=ugos-user-template
VM_MEMORY=2048
VM_CORES=2
VM_STORAGE=${PROXMOX_STORAGE:-local-zfs}
VM_DISK_SIZE=32
UGOS_IMG=${UGOS_IMG:-""}

# Temporäre Installations-IP (vmbr0, erreichbar für SCP)
TEMP_IP=192.168.10.250

echo "=== UGOS Template-VM ${VM_ID} ==="

if [ -z "${UGOS_IMG}" ]; then
  echo "FEHLER: UGOS_IMG nicht gesetzt."
  echo "Verwendung: UGOS_IMG='/path/to/release_...img' bash $0"
  exit 1
fi

if [ ! -f "${UGOS_IMG}" ]; then
  echo "FEHLER: Datei nicht gefunden: ${UGOS_IMG}"
  exit 1
fi

# Schritt 1: Basis-VM erstellen (Debian 12 als Ausgangspunkt)
echo "Schritt 1: VM ${VM_ID} anlegen..."

# Option A: Vorhandenes Debian-12-Template klonen (schneller)
DEBIAN_CLONE_ID=${DEBIAN_CLONE_ID:-""}
if [ -n "${DEBIAN_CLONE_ID}" ]; then
  echo "Klone Debian-Template ${DEBIAN_CLONE_ID} → VM ${VM_ID}..."
  qm clone "${DEBIAN_CLONE_ID}" ${VM_ID} --name "${VM_NAME}" --full 1 --storage "${VM_STORAGE}"
  qm set ${VM_ID} \
    --memory ${VM_MEMORY} \
    --cores ${VM_CORES} \
    --net0 "virtio,bridge=vmbr0"
else
  # Option B: Neue VM ohne Betriebssystem (manuelle Debian-Installation nötig)
  echo "Neue VM ${VM_ID} anlegen (ohne OS — manuelle Installation erforderlich)..."
  qm create ${VM_ID} \
    --name "${VM_NAME}" \
    --memory ${VM_MEMORY} \
    --cores ${VM_CORES} \
    --net0 "virtio,bridge=vmbr0" \
    --scsi0 "${VM_STORAGE}:${VM_DISK_SIZE}" \
    --boot order=scsi0 \
    --bios ovmf \
    --machine q35 \
    --serial0 socket \
    --vga serial0 \
    --agent enabled=1 \
    --onboot 0

  echo ""
  echo "HINWEIS: VM ${VM_ID} wurde ohne OS angelegt."
  echo "  1. Debian 12 netinstall-ISO in Proxmox hochladen"
  echo "  2. VM ${VM_ID} → Hardware → CD/DVD → ISO auswählen"
  echo "  3. VM starten + Debian minimal installieren (SSH aktivieren, kein Desktop)"
  echo "  4. Danach dieses Skript mit DEBIAN_CLONE_ID=<debian_tpl_id> erneut ausführen"
  echo "     ODER Schritt 2 manuell fortsetzen:"
  echo ""
  echo "     UGOS_IMG=\"${UGOS_IMG}\" SKIP_CREATE=1 bash $0"
  exit 0
fi

# Schritt 2: Firmware-Paket übertragen
echo "Schritt 2: UGOS-Firmware → VM ${VM_ID} (${TEMP_IP}) übertragen..."

# Netzwerk-IP temporär setzen
qm set ${VM_ID} --net0 "virtio,bridge=vmbr0,ip=${TEMP_IP}/24,gw=192.168.10.1"

qm start ${VM_ID}
echo "Warte bis VM bereit (SSH)..."
for i in $(seq 1 60); do
  ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no root@${TEMP_IP} "true" 2>/dev/null && break
  sleep 5
done

UGOS_DIR=$(dirname "${UGOS_IMG}")
UGOS_FOLDER="${UGOS_IMG%.img}"  # Entpackter Ordner (gleichnamig ohne .img)

if [ -d "${UGOS_FOLDER}" ]; then
  echo "Übertraге entpackten Ordner: ${UGOS_FOLDER}"
  scp -r -o StrictHostKeyChecking=no "${UGOS_FOLDER}" root@${TEMP_IP}:/tmp/ugos-firmware/
else
  echo "Übertrage IMG-Datei: ${UGOS_IMG}"
  scp -o StrictHostKeyChecking=no "${UGOS_IMG}" root@${TEMP_IP}:/tmp/release_ugos.img
fi

# Schritt 3: UGOS-Installer ausführen
echo "Schritt 3: UGOS-Installer ausführen (ugpt upgrade)..."
ssh -o StrictHostKeyChecking=no root@${TEMP_IP} << 'SSHEOF'
set -e
# Entpackten Ordner nutzen falls vorhanden, sonst .img direkt
FIRMWARE_DIR="/tmp/ugos-firmware"
if [ -d "${FIRMWARE_DIR}" ]; then
  INSTALLER="${FIRMWARE_DIR}/ugospro-upgrade"
  # Komprimiertes .img suchen
  IMG_FILE=$(ls /tmp/ugos-firmware/release_*.img 2>/dev/null | head -1 || echo "")
else
  INSTALLER=$(ls /tmp/release_ugos.img)
  IMG_FILE="${INSTALLER}"
fi
chmod +x "${FIRMWARE_DIR}/ugospro-upgrade" 2>/dev/null || true
chmod +x "${FIRMWARE_DIR}/ugpt" 2>/dev/null || true
echo "Starte UGOS-Installation..."
cd "${FIRMWARE_DIR}"
./ugospro-upgrade "${IMG_FILE:-${FIRMWARE_DIR}/release_*.img}"
echo "UGOS-Installer abgeschlossen — VM wird neu gestartet."
SSHEOF

echo "Schritt 4: VM neu starten → bootet jetzt UGOS"
qm reboot ${VM_ID}

echo ""
echo "=================================================================="
echo "  VM ${VM_ID} startet neu mit UGOS."
echo ""
echo "  Manueller Schritt erforderlich:"
echo "  1. Proxmox UI → VM ${VM_ID} → Konsole öffnen"
echo "  2. UGOS-Ersteinrichtungs-Wizard abschließen"
echo "     (Admin-Account anlegen, Netzwerk prüfen)"
echo "  3. Danach Template einfrieren:"
echo "     qm stop ${VM_ID} && qm template ${VM_ID}"
echo ""
echo "  Bridge konfigurieren (.env):"
echo "  USER_DASHBOARD=ugos"
echo "  UGOS_TEMPLATE_ID=${VM_ID}"
echo "=================================================================="
