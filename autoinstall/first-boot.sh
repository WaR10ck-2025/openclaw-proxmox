#!/bin/bash
# first-boot.sh — OpenClaw Basis-Plattform Setup
#
# Läuft EINMAL nach dem ersten Proxmox-Boot (via first-boot.service).
# Deployt die drei Basis-LXCs: Nginx Proxy Manager, CasaOS, Deployment Hub.
# Alle weiteren Services über CasaOS App-Store installierbar.
#
# Voraussetzungen:
#   - Proxmox VE 8.x installiert + gebootet
#   - LUKS entsperrt (System läuft)
#   - Internetzugang (DHCP aktiv)
#
# Logs: journalctl -u openclaw-first-boot -f

set -e

LOG_FILE="/var/log/openclaw-first-boot.log"
DONE_FLAG="/etc/openclaw-setup.done"
REPO_URL="https://github.com/WaR10ck-2025/openclaw-proxmox.git"
REPO_DIR="/opt/openclaw-proxmox"
SCRIPTS="$REPO_DIR/scripts"
TEMPLATE="debian-12-standard_12.12-1_amd64.tar.zst"

# Logging-Helper
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
log_section() { log ""; log "══════════════════════════════════════════════"; log "  $*"; log "══════════════════════════════════════════════"; }

log_section "OpenClaw First-Boot Setup startet"

# ── Schritt 1: Warten bis Netzwerk bereit ─────────────────────────────────
log "Warte auf Netzwerkverbindung..."
for i in $(seq 1 30); do
  if ping -c1 -W2 1.1.1.1 &>/dev/null; then
    log "✓ Netzwerk erreichbar"
    break
  fi
  [ "$i" -eq 30 ] && { log "✗ Kein Netzwerk nach 60s — abbruch"; exit 1; }
  sleep 2
done

# ── Schritt 2: Proxmox Repos fixen (Enterprise → No-Subscription) ─────────
log_section "APT Repos konfigurieren"
# Enterprise-Repos deaktivieren (kein Abo → 401 Fehler bei apt-get update)
for f in /etc/apt/sources.list.d/pve-enterprise.sources \
          /etc/apt/sources.list.d/ceph.sources; do
  if [ -f "$f" ] && ! grep -q "^Enabled: no" "$f"; then
    echo "Enabled: no" >> "$f"
    log "  Deaktiviert: $f"
  fi
done

# No-Subscription Repo hinzufügen falls nicht vorhanden
if [ ! -f /etc/apt/sources.list.d/pve-no-subscription.list ]; then
  echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" \
    > /etc/apt/sources.list.d/pve-no-subscription.list
  log "  No-Subscription Repo hinzugefügt"
fi
log "✓ APT Repos konfiguriert"

# ── Schritt 3: Basis-Pakete ───────────────────────────────────────────────
log_section "Basis-Pakete installieren"
apt-get update -qq
apt-get install -y -qq git curl

# ── Schritt 4: Repo klonen ────────────────────────────────────────────────
log_section "openclaw-proxmox Repo klonen"
if [ -d "$REPO_DIR/.git" ]; then
  log "Repo bereits vorhanden — aktualisiere..."
  cd "$REPO_DIR" && git pull --quiet
else
  git clone --quiet "$REPO_URL" "$REPO_DIR"
  log "✓ Repo geklont: $REPO_DIR"
fi

# ── Schritt 4: Debian 12 LXC Template ────────────────────────────────────
log_section "Debian 12 Template herunterladen"
pveam update 2>&1 | tail -1
if ! pveam list local 2>/dev/null | grep -q "$TEMPLATE"; then
  pveam download local "$TEMPLATE"
  log "✓ Template heruntergeladen"
else
  log "✓ Template bereits vorhanden"
fi

# ── Schritt 5: Basis-LXCs anlegen (parallel) ──────────────────────────────
log_section "LXC 110 + 120 + 170: Parallel-Installation"
log "Starte alle drei LXCs gleichzeitig..."

bash "$SCRIPTS/install-lxc-reverse-proxy.sh"   > /tmp/lxc-110.log 2>&1 & PID_110=$!
bash "$SCRIPTS/install-lxc-casaos.sh"           > /tmp/lxc-120.log 2>&1 & PID_120=$!
bash "$SCRIPTS/install-lxc-deployment-hub.sh"   > /tmp/lxc-170.log 2>&1 & PID_170=$!

INSTALL_FAIL=0
wait $PID_110 || { log "✗ LXC 110 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }
wait $PID_120 || { log "✗ LXC 120 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }
wait $PID_170 || { log "✗ LXC 170 fehlgeschlagen (Exit: $?)"; INSTALL_FAIL=1; }

cat /tmp/lxc-110.log >> "$LOG_FILE"
cat /tmp/lxc-120.log >> "$LOG_FILE"
cat /tmp/lxc-170.log >> "$LOG_FILE"

[ "$INSTALL_FAIL" -eq 0 ] || { log "✗ LXC-Installation fehlgeschlagen — Setup abgebrochen"; exit 1; }

# ── Schritt 6: ZFS-Unlock Service aktivieren (falls noch nicht) ───────────
if [ -f "$REPO_DIR/autoinstall/zfs-unlock.service" ]; then
  cp "$REPO_DIR/autoinstall/zfs-unlock.sh" /usr/local/bin/
  chmod +x /usr/local/bin/zfs-unlock.sh
  cp "$REPO_DIR/autoinstall/zfs-unlock.service" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable zfs-unlock.service
  log "✓ ZFS-Unlock Service aktiviert (für spätere ZFS Pools)"
fi

# ── Schritt 7: Optional — YubiKey-Enrollment ──────────────────────────────
# YubiKey FIDO2 Enrollment ist optional und kann jederzeit manuell ausgeführt werden.
# Automatisch nur wenn YubiKey beim ersten Boot eingesteckt ist:
if command -v systemd-cryptenroll &>/dev/null; then
  if lsusb 2>/dev/null | grep -qi "yubico\|1050:"; then
    log "YubiKey erkannt — starte optionales LUKS FIDO2 Enrollment..."
    bash "$REPO_DIR/autoinstall/yubikey-enroll.sh" \
      2>&1 | tee -a "$LOG_FILE" || \
      log "YubiKey-Enrollment übersprungen (kann manuell wiederholt werden)"
  else
    log "Info: Kein YubiKey erkannt — Passphrase-only Modus aktiv"
    log "      Optional nachholen: bash $REPO_DIR/autoinstall/yubikey-enroll.sh"
  fi
fi

# ── Schritt 8: Verschlüsselte ZFS Datendisks prüfen ──────────────────────
log_section "Datendisks prüfen (LUKS/ZFS)"
# Alle Disks auflisten die NICHT die System-Disk sind
SYS_DISK=$(lsblk -no pkname $(findmnt -n -o SOURCE /) 2>/dev/null | head -1 || echo "sda")
EXTRA_DISKS=$(lsblk -dno NAME,TYPE | awk '$2=="disk" {print $1}' | grep -v "^$SYS_DISK$" || true)

if [ -n "$EXTRA_DISKS" ]; then
  log "Zusätzliche Disks gefunden: $EXTRA_DISKS"
  log "  → Verschlüsselten ZFS Pool anlegen:"
  log "     bash $REPO_DIR/autoinstall/zfs-pool-create.sh"
else
  log "Info: Keine zusätzlichen Datendisks — ZFS Pool kann später hinzugefügt werden"
  log "      bash $REPO_DIR/autoinstall/zfs-pool-create.sh"
fi

# ── Schritt 9: Status-Ausgabe ─────────────────────────────────────────────
log_section "Setup abgeschlossen"
PROXMOX_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1)

log "✓ LXC 110 (Nginx Proxy Manager): http://192.168.10.140:81"
log "  Login: admin@example.com / changeme  ← SOFORT ÄNDERN!"
log "✓ LXC 120 (CasaOS Dashboard):    http://192.168.10.141"
log "✓ LXC 170 (Deployment Hub):     http://192.168.10.170:8100"
log ""
log "Proxmox Web-UI: https://${PROXMOX_IP}:8006"
log "SSH:            ssh root@${PROXMOX_IP}"
log ""
log "Weitere Services: CasaOS App-Store → http://192.168.10.141"
log ""
log "Optional — YubiKey nachträglich enrollen:"
log "  bash $REPO_DIR/autoinstall/yubikey-enroll.sh"
log ""
log "Optional — Verschlüsselten ZFS Datenpool anlegen:"
log "  bash $REPO_DIR/autoinstall/zfs-pool-create.sh"

# Fertig — nie wieder starten
touch "$DONE_FLAG"
log "✓ First-Boot abgeschlossen. Flag: $DONE_FLAG"
