#!/bin/bash
# create-rescue-usb.sh — OpenClaw Rescue-USB erstellen
#
# Erstellt einen bootfähigen USB-Stick der SOWOHL das Proxmox-ISO
# als auch alle Backup-Daten auf einem einzigen Datenträger enthält.
#
# ── Drei Modi ──────────────────────────────────────────────────────────────
#
#  Modus A — Standard (dd + neue ext4-Partition)
#    Leeren USB-Stick neu partitionieren:
#    Partition 1: bootbares ISO  |  Partition 2: ext4, OPENCLAW-BAK
#
#    create-rescue-usb.sh --iso proxmox-openclaw.iso --device /dev/sdX
#
#  Modus B — Ventoy (bestehende Ventoy-Installation, empfohlen)
#    Nur Dateien kopieren, keine Repartitionierung:
#    ISO + openclaw-backups/ Ordner in die exFAT Ventoy-Partition
#
#    create-rescue-usb.sh --ventoy --device /dev/sdX --iso proxmox-openclaw.iso
#
#  Modus C — Ventoy + dedizierte Partition
#    ISO in Ventoy-Partition + neue ext4-Partition 3 für Backup-Daten
#
#    create-rescue-usb.sh --ventoy --add-partition --device /dev/sdX
#
# ── Optionen ───────────────────────────────────────────────────────────────
#   --iso <Pfad>          ISO-Datei (Modus A + B)
#   --device <Gerät>      USB Block-Device (z.B. /dev/sdb)
#   --ventoy              Ventoy-Modus aktivieren (B oder C)
#   --add-partition       Zusätzliche OPENCLAW-BAK Partition erstellen (Modus C)
#   --copy-from <Pfad>    Backup-Daten von hier auf USB kopieren
#                         (z.B. /mnt/backup-usb wenn aktueller Backup-USB gemountet)

set -e

# ── Farben + Hilfsfunktionen ─────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓${NC} $*"; }
warn() { echo -e "${YELLOW}  ⚠ ${NC} $*"; }
err()  { echo -e "${RED}  ✗${NC} $*"; exit 1; }
info() { echo -e "${BLUE}  →${NC} $*"; }
hdr()  { echo -e "\n${BOLD}$*${NC}"; }

usage() {
  echo ""
  echo -e "${BOLD}OpenClaw Rescue-USB erstellen${NC}"
  echo ""
  echo "  Modus A — Standard (neuer USB-Stick):"
  echo "    $0 --iso proxmox-openclaw.iso --device /dev/sdX [--copy-from /mnt/backup-usb]"
  echo ""
  echo "  Modus B — Ventoy (bestehende Installation):"
  echo "    $0 --ventoy --device /dev/sdX --iso proxmox-openclaw.iso [--copy-from /mnt/backup-usb]"
  echo ""
  echo "  Modus C — Ventoy + eigene Backup-Partition:"
  echo "    $0 --ventoy --add-partition --device /dev/sdX [--copy-from /mnt/backup-usb]"
  echo ""
  exit 0
}

# ── Argument-Parsing ──────────────────────────────────────────────────────
ISO_FILE=""
DEVICE=""
VENTOY_MODE=false
ADD_PARTITION=false
COPY_FROM=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --iso)           ISO_FILE="$2";    shift 2 ;;
    --device)        DEVICE="$2";     shift 2 ;;
    --ventoy)        VENTOY_MODE=true; shift ;;
    --add-partition) ADD_PARTITION=true; shift ;;
    --copy-from)     COPY_FROM="$2";  shift 2 ;;
    --help|-h)       usage ;;
    *) shift ;;
  esac
done

[ -z "$DEVICE" ] && err "Kein --device angegeben. Beispiel: --device /dev/sdb"
[ ! -b "$DEVICE" ] && err "$DEVICE ist kein Block-Device"

# ── System-Disk Schutz ────────────────────────────────────────────────────
ROOT_DISK=$(lsblk -no pkname "$(findmnt -n -o SOURCE /)" 2>/dev/null | head -1 || echo "")
DEV_BASE=$(basename "$DEVICE")
if [ -n "$ROOT_DISK" ] && [ "$DEV_BASE" = "$ROOT_DISK" ]; then
  err "SICHERHEIT: $DEVICE ist die System-Disk! Abgebrochen."
fi

# ── Abhängigkeiten prüfen ────────────────────────────────────────────────
for cmd in parted mkfs.ext4 partprobe rsync; do
  if ! command -v "$cmd" &>/dev/null; then
    warn "$cmd nicht gefunden — installiere..."
    apt-get install -y -qq "${cmd%.*}" 2>/dev/null || true
  fi
done

# ══════════════════════════════════════════════════════════════════════════
#  MODUS B — VENTOY (nur Dateien kopieren)
# ══════════════════════════════════════════════════════════════════════════
if [ "$VENTOY_MODE" = "true" ] && [ "$ADD_PARTITION" = "false" ]; then
  hdr "Modus B: Ventoy-USB befüllen"

  # Ventoy-Partition finden
  VENTOY_PART=""
  for part in "${DEVICE}1" "${DEVICE}p1"; do
    if [ -b "$part" ]; then
      LABEL=$(blkid -s LABEL -o value "$part" 2>/dev/null || true)
      if [ "$LABEL" = "Ventoy" ]; then
        VENTOY_PART="$part"
        break
      fi
    fi
  done

  [ -z "$VENTOY_PART" ] && err "Keine Ventoy-Partition auf $DEVICE gefunden (Label='Ventoy'). Ist Ventoy installiert?"

  info "Ventoy-Partition: $VENTOY_PART"
  VENTOY_MOUNT="/mnt/openclaw-ventoy-$$"
  mkdir -p "$VENTOY_MOUNT"
  trap "umount '$VENTOY_MOUNT' 2>/dev/null; rmdir '$VENTOY_MOUNT' 2>/dev/null; true" EXIT

  mount "$VENTOY_PART" "$VENTOY_MOUNT"
  VENTOY_FS=$(blkid -s TYPE -o value "$VENTOY_PART" 2>/dev/null || echo "exfat")
  ok "Ventoy-Partition gemountet ($VENTOY_FS)"

  # ISO kopieren
  if [ -n "$ISO_FILE" ]; then
    [ ! -f "$ISO_FILE" ] && err "ISO-Datei nicht gefunden: $ISO_FILE"
    ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
    info "ISO kopieren: $(basename "$ISO_FILE") ($ISO_SIZE)..."
    cp --progress "$ISO_FILE" "$VENTOY_MOUNT/" 2>/dev/null || \
      rsync -ah --progress "$ISO_FILE" "$VENTOY_MOUNT/"
    ok "ISO kopiert: $(basename "$ISO_FILE")"
  fi

  # Backup-Verzeichnisstruktur erstellen
  info "openclaw-backups/ Verzeichnisstruktur erstellen..."
  mkdir -p "${VENTOY_MOUNT}/openclaw-backups/dump"
  mkdir -p "${VENTOY_MOUNT}/openclaw-backups/configs"
  mkdir -p "${VENTOY_MOUNT}/openclaw-backups/appdata"
  mkdir -p "${VENTOY_MOUNT}/openclaw-backups/keys"
  ok "Verzeichnisstruktur erstellt"

  # Backup-Daten kopieren
  if [ -n "$COPY_FROM" ]; then
    _copy_backups "$COPY_FROM" "${VENTOY_MOUNT}/openclaw-backups"
  fi

  umount "$VENTOY_MOUNT" && rmdir "$VENTOY_MOUNT"
  trap - EXIT

  VENTOY_FREE=$(df -BG "$VENTOY_PART" 2>/dev/null | tail -1 | awk '{print $4}' || echo "?")
  echo ""
  ok "Ventoy-USB fertig!"
  echo ""
  echo "  Inhalt:"
  echo "    ISO:     $(basename "${ISO_FILE:-kein ISO}")"
  echo "    Backups: ${VENTOY_MOUNT}/openclaw-backups/ (Frei: ${VENTOY_FREE})"
  echo ""
  echo "  Nächste Schritte:"
  echo "    1. USB einstecken + booten → Ventoy-Menü"
  echo "    2. proxmox-openclaw.iso auswählen"
  echo "    3. Proxmox installiert sich automatisch"
  echo "    4. First-Boot zeigt Menü → [2] Disaster Recovery wählen"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
#  MODUS C — VENTOY + NEUE OPENCLAW-BAK PARTITION
# ══════════════════════════════════════════════════════════════════════════
if [ "$VENTOY_MODE" = "true" ] && [ "$ADD_PARTITION" = "true" ]; then
  hdr "Modus C: Ventoy-USB + neue OPENCLAW-BAK Partition"

  # Prüfen ob GPT (Ventoy verwendet GPT)
  PARTITION_TABLE=$(parted -s "$DEVICE" print 2>/dev/null | grep "Partition Table" | awk '{print $3}')
  [ "$PARTITION_TABLE" != "gpt" ] && err "GPT-Partitionstabelle erforderlich (aktiv: $PARTITION_TABLE). Ventoy verwendet GPT."

  # Letzten belegten Sektor ermitteln
  LAST_SECTOR=$(parted -s "$DEVICE" unit s print 2>/dev/null | grep "^ [0-9]" | awk '{print $3}' | tr -d 's' | sort -n | tail -1)
  START_SECTOR=$((LAST_SECTOR + 1))
  info "Neue Partition ab Sektor $START_SECTOR"

  warn "Neue Partition 3 auf $DEVICE erstellen..."
  read -rp "  Fortfahren? [j/N] " CONFIRM
  [[ ! "$CONFIRM" =~ ^[jJyY]$ ]] && { echo "  Abgebrochen."; exit 0; }

  parted -s "$DEVICE" mkpart primary ext4 "${START_SECTOR}s" 100%
  partprobe "$DEVICE"
  sleep 3

  # Neue Partition finden
  BACKUP_PART=$(lsblk -no NAME "$DEVICE" | tail -1)
  BACKUP_PART="/dev/$BACKUP_PART"
  [ ! -b "$BACKUP_PART" ] && err "Neue Partition nicht gefunden"

  mkfs.ext4 -L "OPENCLAW-BAK" -q "$BACKUP_PART"
  ok "Partition erstellt + formatiert: $BACKUP_PART (OPENCLAW-BAK)"

  # Backup-Daten kopieren
  if [ -n "$COPY_FROM" ]; then
    BACKUP_MOUNT="/mnt/openclaw-bakpart-$$"
    mkdir -p "$BACKUP_MOUNT"
    mount "$BACKUP_PART" "$BACKUP_MOUNT"
    _copy_backups "$COPY_FROM" "${BACKUP_MOUNT}/openclaw-backups"
    umount "$BACKUP_MOUNT" && rmdir "$BACKUP_MOUNT"
  fi

  PART_SIZE=$(lsblk -no SIZE "$BACKUP_PART" 2>/dev/null || echo "?")
  echo ""
  ok "Modus C abgeschlossen!"
  echo "  Partition 3: $BACKUP_PART ($PART_SIZE, Label=OPENCLAW-BAK)"
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════
#  MODUS A — STANDARD (dd + neue ext4-Partition)
# ══════════════════════════════════════════════════════════════════════════
hdr "Modus A: Standard Rescue-USB (dd + Dual-Partition)"

[ -z "$ISO_FILE" ] && err "Kein --iso angegeben. Beispiel: --iso proxmox-openclaw.iso"
[ ! -f "$ISO_FILE" ] && err "ISO-Datei nicht gefunden: $ISO_FILE"

# Größen-Check (min. 8 GB)
DEVICE_GB=$(lsblk -bno SIZE "$DEVICE" 2>/dev/null | head -1 | awk '{printf "%.0f", $1/1024/1024/1024}')
ISO_GB=$(du -BG "$ISO_FILE" | cut -f1 | tr -d 'G')
[ "${DEVICE_GB:-0}" -lt 8 ] && err "USB-Stick zu klein (${DEVICE_GB}GB). Mindestens 8 GB empfohlen."

ISO_SIZE=$(du -sh "$ISO_FILE" | cut -f1)
echo ""
echo -e "  ${BOLD}USB-Gerät:${NC}  $DEVICE  (${DEVICE_GB}GB)"
echo -e "  ${BOLD}ISO-Datei:${NC}  $ISO_FILE  ($ISO_SIZE)"
echo ""
echo -e "  ${RED}WARNUNG: ALLE DATEN auf $DEVICE werden gelöscht!${NC}"
read -rp "  Fortfahren? [j/N] " CONFIRM
[[ ! "$CONFIRM" =~ ^[jJyY]$ ]] && { echo "  Abgebrochen."; exit 0; }

# Schritt 1: ISO auf USB schreiben
hdr "Schritt 1/4: ISO schreiben (dd)..."
dd if="$ISO_FILE" of="$DEVICE" bs=4M status=progress conv=fsync
sync
ok "ISO geschrieben"

# Schritt 2: Partitionstabelle neu einlesen
hdr "Schritt 2/4: Partitionstabelle neu einlesen..."
partprobe "$DEVICE"
sleep 3

# Schritt 3: Letzten ISO-Sektor + Freiraum ermitteln
hdr "Schritt 3/4: Partition 2 (OPENCLAW-BAK) erstellen..."
LAST_ISO_SECTOR=$(sfdisk -d "$DEVICE" 2>/dev/null | grep "start=" | awk -F',' '{
  for(i=1;i<=NF;i++) if($i~"start=") {gsub(/.*start=/,"",$i); gsub(/[^0-9].*/,"",$i); start=$i}
  if($i~"size=") {gsub(/.*size=/,"",$i); gsub(/[^0-9].*/,"",$i); size=$i}
} END {print start+size}' || echo "0")

if [ "${LAST_ISO_SECTOR:-0}" -eq 0 ]; then
  # Fallback: ISO-Bytes in Sektoren umrechnen + 10% Puffer
  ISO_BYTES=$(stat -c%s "$ISO_FILE")
  LAST_ISO_SECTOR=$(( (ISO_BYTES / 512) + 2048 ))
fi

START_SECTOR=$((LAST_ISO_SECTOR + 2048))  # 2048 Sektoren Alignment-Puffer
info "Neue Partition ab Sektor $START_SECTOR"

parted -s "$DEVICE" mkpart primary ext4 "${START_SECTOR}s" 100%
partprobe "$DEVICE"
sleep 3

# Neue Partition ermitteln
if [ -b "${DEVICE}2" ]; then
  BACKUP_PART="${DEVICE}2"
elif [ -b "${DEVICE}p2" ]; then
  BACKUP_PART="${DEVICE}p2"
else
  err "Partition 2 nicht gefunden nach partprobe"
fi

mkfs.ext4 -L "OPENCLAW-BAK" -q "$BACKUP_PART"
ok "Partition 2 erstellt: $BACKUP_PART (OPENCLAW-BAK ext4)"

# Schritt 4: Backup-Daten kopieren (optional)
hdr "Schritt 4/4: Backup-Daten..."
if [ -n "$COPY_FROM" ]; then
  BACKUP_MOUNT="/mnt/openclaw-newusb-$$"
  mkdir -p "$BACKUP_MOUNT"
  mount "$BACKUP_PART" "$BACKUP_MOUNT"
  _copy_backups "$COPY_FROM" "${BACKUP_MOUNT}/openclaw-backups"
  umount "$BACKUP_MOUNT" && rmdir "$BACKUP_MOUNT"
else
  # Struktur anlegen damit first-boot.sh sie finden kann
  BACKUP_MOUNT="/mnt/openclaw-newusb-$$"
  mkdir -p "$BACKUP_MOUNT"
  mount "$BACKUP_PART" "$BACKUP_MOUNT"
  mkdir -p "${BACKUP_MOUNT}/openclaw-backups/"{dump,configs,appdata,keys}
  umount "$BACKUP_MOUNT" && rmdir "$BACKUP_MOUNT"
  warn "Keine Backup-Daten kopiert — Ordnerstruktur angelegt"
  info "Backup-Daten manuell kopieren:"
  info "  mount $BACKUP_PART /mnt/backup-usb"
  info "  rsync -av /mnt/old-backup-usb/openclaw-backups/ /mnt/backup-usb/openclaw-backups/"
fi

# ── Abschluss ────────────────────────────────────────────────────────────
PART1_SIZE=$(lsblk -no SIZE "${DEVICE}1" 2>/dev/null || echo "?")
PART2_SIZE=$(lsblk -no SIZE "$BACKUP_PART" 2>/dev/null || echo "?")

echo ""
ok "Rescue-USB fertig!"
echo ""
echo "  Partitionen:"
echo "    Partition 1: ${DEVICE}1  ($PART1_SIZE) — Bootbares Proxmox-ISO"
echo "    Partition 2: $BACKUP_PART  ($PART2_SIZE) — OPENCLAW-BAK (Backup-Daten)"
echo ""
echo "  Nächste Schritte:"
echo "    1. USB einstecken + von USB booten (BIOS/UEFI: Boot-Order prüfen)"
echo "    2. Proxmox installiert sich automatisch (~3 Min)"
echo "    3. First-Boot zeigt Menü → [2] Disaster Recovery wählen"
echo "    4. System wird vollständig aus Backup wiederhergestellt (~30-60 Min)"
echo ""

# ── Hilfsfunktion: Backup-Daten kopieren ────────────────────────────────
# (wird oben referenziert — Bash lädt Funktionen erst beim Aufruf, daher am Ende definieren
#  oder mit einer Wrapper-Funktion arbeiten — hier verwenden wir Inline-Logik)
_copy_backups() {
  local src="$1" dst="$2"
  mkdir -p "$dst"/{dump,configs,appdata,keys}

  if [ ! -d "${src}/openclaw-backups" ]; then
    warn "--copy-from: Kein openclaw-backups/ Verzeichnis unter $src — übersprungen"
    return
  fi

  info "Backup-Daten kopieren von $src..."
  COPY_SIZE=$(du -sh "${src}/openclaw-backups" 2>/dev/null | cut -f1)
  info "  Größe: $COPY_SIZE"

  rsync -ah --progress \
    "${src}/openclaw-backups/" \
    "$dst/"

  ok "Backup-Daten kopiert ($COPY_SIZE)"
}
