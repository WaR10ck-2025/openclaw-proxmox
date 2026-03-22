#!/bin/bash
# build-iso.sh — Custom Proxmox ISO mit OpenClaw Autoinstall erstellen
#
# Erstellt ein bootfähiges USB-Image / ISO das:
#   1. Proxmox VE automatisch installiert (kein manueller Input)
#   2. LUKS2 Verschlüsselung der System-Disk einrichtet
#   3. Beim ersten Boot: Nginx Proxy Manager, CasaOS + Deployment Hub deployt
#
# Voraussetzungen (Linux/WSL2):
#   apt install xorriso squashfs-tools p7zip-full syslinux-utils curl git
#   Optional: apt install proxmox-auto-install-assistant (auf Debian/Proxmox)
#
# Verwendung:
#   bash build-iso.sh                                   # alles automatisch
#   bash build-iso.sh --pve-iso /path/to/proxmox-ve.iso # eigene ISO nutzen
#   bash build-iso.sh --output /dev/sdb                 # direkt auf USB schreiben
#
# Output:
#   proxmox-openclaw.iso — fertiges ISO (ca. 1 GB)
#
# USB erstellen (nach build):
#   dd if=proxmox-openclaw.iso of=/dev/sdX bs=4M status=progress

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORK_DIR="/tmp/proxmox-openclaw-build"
OUTPUT_ISO="$SCRIPT_DIR/proxmox-openclaw.iso"
PVE_ISO=""
WRITE_TO_USB=""
INTERACTIVE=false

# Parameter parsen
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pve-iso) PVE_ISO="$2"; shift 2 ;;
    --output)  WRITE_TO_USB="$2"; shift 2 ;;
    --interactive|--guided) INTERACTIVE=true; shift ;;
    --help|-h)
      echo "Verwendung: $0 [--pve-iso /path/to.iso] [--output /dev/sdX] [--interactive]"
      echo ""
      echo "  (ohne --interactive)  Vollautomatische Installation via answer.toml"
      echo "  --interactive         Benutzergeführter Proxmox-Wizard + automatischer first-boot"
      exit 0 ;;
    *) echo "Unbekannter Parameter: $1"; exit 1 ;;
  esac
done

if $INTERACTIVE; then
  OUTPUT_ISO="$SCRIPT_DIR/proxmox-openclaw-interactive.iso"
fi

echo "╔══════════════════════════════════════════════════════════╗"
echo "║       OpenClaw OS — Custom Proxmox ISO Builder         ║"
echo "╚══════════════════════════════════════════════════════════╝"
if $INTERACTIVE; then
  echo "  Modus: INTERAKTIV (Proxmox-Wizard + automatischer first-boot)"
else
  echo "  Modus: AUTOMATISCH (vollständig via answer.toml)"
fi
echo ""

# Root-Check
[ "$(id -u)" -ne 0 ] && { echo "✗ Root erforderlich (für ISO-Modifikation)."; exit 1; }

# ── Abhängigkeiten prüfen ─────────────────────────────────────────────────
echo "► Abhängigkeiten prüfen..."
MISSING=()
for CMD in xorriso unsquashfs mksquashfs 7z curl git isohybrid; do
  command -v "$CMD" &>/dev/null || MISSING+=("$CMD")
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "  Fehlende Tools: ${MISSING[*]}"
  echo "  Installiere..."
  apt-get update -qq
  apt-get install -y -qq xorriso squashfs-tools p7zip-full syslinux-utils curl git 2>/dev/null || true
fi

# proxmox-auto-install-assistant verfügbar?
USE_PVE_ASSISTANT=false
if command -v proxmox-auto-install-assistant &>/dev/null; then
  USE_PVE_ASSISTANT=true
  echo "  ✓ proxmox-auto-install-assistant verfügbar (bevorzugter Modus)"
else
  echo "  ℹ  proxmox-auto-install-assistant nicht verfügbar → manueller ISO-Bau"
fi

# ── Proxmox VE ISO beschaffen ─────────────────────────────────────────────
echo ""
echo "► Proxmox VE ISO..."

PVE_VERSION="8.4"  # Aktuellste stabile Version
PVE_ISO_NAME="proxmox-ve_${PVE_VERSION}-1.iso"
PVE_ISO_URL="https://enterprise.proxmox.com/iso/${PVE_ISO_NAME}"

if [ -z "$PVE_ISO" ]; then
  # Nach lokaler ISO suchen
  for SEARCH_PATH in "$SCRIPT_DIR" "$SCRIPT_DIR/.." /tmp ~/Downloads; do
    FOUND=$(find "$SEARCH_PATH" -maxdepth 1 -name "proxmox-ve_*.iso" 2>/dev/null | head -1)
    [ -n "$FOUND" ] && PVE_ISO="$FOUND" && break
  done
fi

if [ -n "$PVE_ISO" ] && [ -f "$PVE_ISO" ]; then
  echo "  ✓ Verwende: $PVE_ISO"
else
  echo "  Proxmox VE ISO nicht gefunden."
  echo "  Bitte herunterladen von: https://www.proxmox.com/proxmox-virtual-environment/get-started"
  echo ""
  read -rp "  ISO-Pfad manuell eingeben (oder Enter zum Abbrechen): " MANUAL_ISO
  if [ -n "$MANUAL_ISO" ] && [ -f "$MANUAL_ISO" ]; then
    PVE_ISO="$MANUAL_ISO"
  else
    echo ""
    echo "  Alternativ: ISO direkt herunterladen (wget):"
    echo "  wget -O proxmox-ve.iso '${PVE_ISO_URL}'"
    echo ""
    echo "  ✗ Kein ISO gefunden — abbruch."
    exit 1
  fi
fi

# ── Arbeitsverzeichnis vorbereiten ────────────────────────────────────────
echo ""
echo "► ISO vorbereiten..."
rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR"/{iso-extract,squashfs-extract,iso-new}

# ── Modus A: proxmox-auto-install-assistant (nur für automatischen Modus) ─
# Hinweis: proxmox-auto-install-assistant erfordert immer --fetch-from + answer.toml.
# Im interaktiven Modus wird daher immer Modus B (squashfs) verwendet.
if $USE_PVE_ASSISTANT && ! $INTERACTIVE; then
  echo "  Verwende proxmox-auto-install-assistant (automatischer Modus)..."

  proxmox-auto-install-assistant prepare-iso "$PVE_ISO" \
    --fetch-from iso \
    --answer-file "$SCRIPT_DIR/answer.toml" \
    --output "$OUTPUT_ISO"
  echo "  ✓ Automatische ISO erstellt (answer.toml + auto-install-assistant)"
  echo "  ℹ  First-boot Scripts müssen nach Installation manuell deployt werden."
  echo "     Oder: manueller ISO-Bau (ohne proxmox-auto-install-assistant) für vollständige Automatisierung."

# ── Modus B: Manueller ISO-Bau mit squashfs-Modifikation ─────────────────
# Wird verwendet wenn: proxmox-auto-install-assistant nicht verfügbar ODER --interactive
else
  echo "  Extrahiere ISO-Inhalte..."
  xorriso -osirrox on -indev "$PVE_ISO" -extract / "$WORK_DIR/iso-extract" 2>/dev/null || \
  7z x -o"$WORK_DIR/iso-extract" "$PVE_ISO" -y -bsp0 -bso0 2>/dev/null

  # ISO-Inhalte prüfen
  if [ ! -d "$WORK_DIR/iso-extract" ] || [ -z "$(ls -A "$WORK_DIR/iso-extract" 2>/dev/null)" ]; then
    echo "✗ ISO-Extraktion fehlgeschlagen"
    exit 1
  fi
  echo "  ISO-Inhalte:"
  ls "$WORK_DIR/iso-extract/"

  # answer.toml ins ISO-Root legen (Proxmox liest es beim Booten von dort)
  # Im interaktiven Modus wird answer.toml NICHT kopiert → Installer-Wizard bleibt aktiv
  if ! $INTERACTIVE; then
    echo "  answer.toml → ISO-Root..."
    cp "$SCRIPT_DIR/answer.toml" "$WORK_DIR/iso-extract/answer.toml"
  else
    echo "  ℹ  Interaktiver Modus — answer.toml wird nicht injiziert (Wizard aktiv)"
  fi

  # squashfs Zielsystem extrahieren (pve-base = wird auf Disk installiert)
  # pve-installer.squashfs = nur Installer-UI, wird NICHT auf Disk kopiert!
  SQUASH_FILE=$(find "$WORK_DIR/iso-extract" -name "pve-base.squashfs" 2>/dev/null | head -1)
  [ -z "$SQUASH_FILE" ] && SQUASH_FILE=$(find "$WORK_DIR/iso-extract" -name "*.squashfs" 2>/dev/null | grep -v installer | head -1)

  if [ -z "$SQUASH_FILE" ]; then
    echo "  ℹ  squashfs nicht gefunden — first-boot Scripts werden via Git geklont"
    echo "     (answer.toml Autoinstall funktioniert trotzdem)"
  else
    echo "  squashfs gefunden: $SQUASH_FILE"
    echo "  squashfs extrahieren (kann 2–5 Min dauern)..."

    # Extraktion mit vollem Output für Debugging
    if ! unsquashfs -d "$WORK_DIR/squashfs-extract" "$SQUASH_FILE"; then
      echo "  ✗ unsquashfs fehlgeschlagen — überspringe first-boot Injection"
      echo "  ℹ  Autoinstall via answer.toml funktioniert weiterhin"
      SQUASH_FILE=""
    fi
  fi

  if [ -n "$SQUASH_FILE" ] && [ -d "$WORK_DIR/squashfs-extract" ]; then
    TARGET="$WORK_DIR/squashfs-extract"
    echo "  squashfs-Inhalt:"
    ls "$TARGET/" | head -20

    # Ziel-Verzeichnisse sicherstellen
    mkdir -p "$TARGET/root"
    mkdir -p "$TARGET/etc/systemd/system/multi-user.target.wants"
    mkdir -p "$TARGET/usr/local/bin"
    mkdir -p "$TARGET/etc/proxmox-installer"

    echo "  First-boot Scripts injizieren..."
    install -m 755 "$SCRIPT_DIR/first-boot.sh"      "$TARGET/root/openclaw-first-boot.sh"
    install -m 644 "$SCRIPT_DIR/first-boot.service" "$TARGET/etc/systemd/system/openclaw-first-boot.service"
    install -m 755 "$SCRIPT_DIR/yubikey-enroll.sh"  "$TARGET/root/" 2>/dev/null || true
    install -m 755 "$SCRIPT_DIR/zfs-unlock.sh"      "$TARGET/usr/local/bin/" 2>/dev/null || true
    install -m 644 "$SCRIPT_DIR/zfs-unlock.service" "$TARGET/etc/systemd/system/" 2>/dev/null || true
    install -m 755 "$SCRIPT_DIR/zfs-pool-create.sh" "$TARGET/root/" 2>/dev/null || true

    # systemd service enablen (Symlink)
    ln -sf /etc/systemd/system/openclaw-first-boot.service \
      "$TARGET/etc/systemd/system/multi-user.target.wants/openclaw-first-boot.service" 2>/dev/null || true

    # squashfs neu packen
    echo "  squashfs neu packen (kann 5–10 Min dauern)..."
    rm "$SQUASH_FILE"
    mksquashfs "$WORK_DIR/squashfs-extract" "$SQUASH_FILE" -comp xz -noappend -quiet
    echo "  ✓ squashfs aktualisiert"
  fi

  # ── ISO neu erstellen mit original Boot-Parametern ─────────────────────
  echo "  ISO neu bauen..."

  # Boot-Konfiguration aus Original-ISO auslesen
  MBR_IMG=$(find "$WORK_DIR/iso-extract" -name "boot_hybrid.img" -o -name "isohdpfx.bin" 2>/dev/null | head -1)
  EFI_IMG=$(find "$WORK_DIR/iso-extract" -path "*/grub/efi.img" -o -path "*/efi.img" 2>/dev/null | head -1)
  ELTORITO=$(find "$WORK_DIR/iso-extract" -path "*/grub/i386-pc/eltorito.img" 2>/dev/null | head -1)

  # EFI-Image relativer Pfad
  EFI_REL="${EFI_IMG#$WORK_DIR/iso-extract/}"
  ELTORITO_REL="${ELTORITO#$WORK_DIR/iso-extract/}"

  xorriso -as mkisofs \
    -V "ProxmoxVE" \
    -J -joliet-long -r \
    ${MBR_IMG:+--grub2-mbr "$MBR_IMG"} \
    -partition_offset 16 \
    ${ELTORITO_REL:+-b "$ELTORITO_REL" -no-emul-boot -boot-load-size 4 -boot-info-table --grub2-boot-info} \
    ${EFI_REL:+-eltorito-alt-boot -e "$EFI_REL" -no-emul-boot -isohybrid-gpt-basdat} \
    -o "$OUTPUT_ISO" \
    "$WORK_DIR/iso-extract" 2>&1 | tail -5

  echo "  ✓ Manueller ISO-Bau abgeschlossen"
fi

# ── Aufräumen ─────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

# ── Ergebnis ──────────────────────────────────────────────────────────────
ISO_SIZE=$(du -sh "$OUTPUT_ISO" 2>/dev/null | awk '{print $1}' || echo "?")
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║                    ISO erstellt!                        ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  Output:    $OUTPUT_ISO"
echo "  Größe:     $ISO_SIZE"
echo ""
echo "  USB-Stick erstellen:"
echo "    dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress"
echo "    (sdX = USB-Stick, VORSICHT: alle Daten werden gelöscht!)"
echo ""
echo "  Oder: Balena Etcher / Rufus (Windows) verwenden"
echo ""

# Direkt auf USB schreiben wenn --output angegeben
if [ -n "$WRITE_TO_USB" ]; then
  if [ ! -b "$WRITE_TO_USB" ]; then
    echo "✗ $WRITE_TO_USB ist kein Block-Device"
    exit 1
  fi
  echo "  Schreibe auf USB: $WRITE_TO_USB"
  read -rp "  ALLE DATEN auf $WRITE_TO_USB werden gelöscht! Fortfahren? [j/N] " USB_CONFIRM
  [[ ! "$USB_CONFIRM" =~ ^[jJyY]$ ]] && { echo "  Abgebrochen."; exit 0; }
  dd if="$OUTPUT_ISO" of="$WRITE_TO_USB" bs=4M status=progress
  sync
  echo "  ✓ USB-Stick fertig: $WRITE_TO_USB"
fi

echo "  Nächste Schritte nach Installation:"
if $INTERACTIVE; then
  echo "    1. USB booten → Proxmox Installer-Wizard erscheint"
  echo "    2. Disk, Hostname, Passwort im Wizard konfigurieren → Installieren"
  echo "    3. Neustart → first-boot.service startet LXC 110/120/170"
  echo "    4. Browser: http://<IP> → CasaOS App-Store"
else
  echo "    1. USB booten → Proxmox installiert sich automatisch (kein Input)"
  echo "    2. Neustart → LUKS-Passphrase eingeben"
  echo "    3. first-boot.service startet LXC 110/120/170"
  echo "    4. Browser: http://<IP> → CasaOS App-Store"
fi
echo ""
