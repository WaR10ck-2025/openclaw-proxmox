#!/bin/bash
# restore-hook.sh — OpenClaw Disaster Recovery Engine
#
# Läuft im Kontext von first-boot.sh wenn OPENCLAW-BAK USB erkannt wird.
# Stellt alle LXCs, VMs und App-Daten von der USB-Festplatte wieder her.
#
# Ablauf:
#   Phase 1 — USB mounten
#   Phase 2 — age Private Key kopieren
#   Phase 3 — Layer 1: /etc/pve/ entschlüsseln + wiederherstellen
#   Phase 4 — Proxmox Backup-Storage registrieren
#   Phase 5 — Layer 2: LXCs aus vzdump wiederherstellen (pct restore)
#   Phase 6 — Layer 2: VMs aus vzdump wiederherstellen (qmrestore)
#   Phase 7 — Alle LXCs starten (Infrastruktur zuerst)
#   Phase 8 — Layer 3: App-Daten wiederherstellen

set -e

LOG_FILE="/var/log/openclaw-first-boot.log"
USB_LABEL="OPENCLAW-BAK"
USB_MOUNT="/mnt/backup-usb"
BACKUP_BASE="${USB_MOUNT}/openclaw-backups"
REPO_DIR="/opt/openclaw-proxmox"
REPO_URL="https://github.com/WaR10ck-2025/openclaw-proxmox.git"

log()         { echo "[$(date '+%H:%M:%S')] $*"        | tee -a "$LOG_FILE"; }
log_ok()      { echo "[$(date '+%H:%M:%S')]   ✓ $*"    | tee -a "$LOG_FILE"; }
log_warn()    { echo "[$(date '+%H:%M:%S')]   ⚠  $*"   | tee -a "$LOG_FILE"; }
log_err()     { echo "[$(date '+%H:%M:%S')]   ✗ $*"    | tee -a "$LOG_FILE"; }
log_section() {
  log ""
  log "══════════════════════════════════════════════"
  log "  $*"
  log "══════════════════════════════════════════════"
}

RESTORE_ERRORS=0

# ── Phase 1: USB mounten ──────────────────────────────────────────────────
log_section "Phase 1: OPENCLAW-BAK USB mounten"
mkdir -p "$USB_MOUNT"
USB_DEV=$(blkid -L "$USB_LABEL" 2>/dev/null || true)
if [ -z "$USB_DEV" ]; then
  log_err "OPENCLAW-BAK USB nicht gefunden — Restore abgebrochen"
  exit 1
fi
mountpoint -q "$USB_MOUNT" || mount "$USB_DEV" "$USB_MOUNT"
log_ok "USB gemountet: $USB_DEV → $USB_MOUNT"
log "  Inhalte: $(du -sh "${BACKUP_BASE}" 2>/dev/null | cut -f1) gesamt"

# ── Phase 2: age Private Key kopieren ────────────────────────────────────
log_section "Phase 2: age Private Key"
mkdir -p /root/.age && chmod 700 /root/.age
AGE_KEY_OK=false

if [ -f "${BACKUP_BASE}/keys/age-private-key.txt" ]; then
  cp "${BACKUP_BASE}/keys/age-private-key.txt" /root/.age/key.txt
  chmod 600 /root/.age/key.txt
  log_ok "age Private Key von USB kopiert"
  AGE_KEY_OK=true
else
  log_warn "age Private Key nicht auf USB — Layer 1 Entschlüsselung übersprungen"
  log_warn "  Erwartet unter: ${BACKUP_BASE}/keys/age-private-key.txt"
fi

# ── Phase 2b: age Binary installieren ─────────────────────────────────────
if [ "$AGE_KEY_OK" = "true" ]; then
  if ! command -v age &>/dev/null; then
    log "  age nicht gefunden — installiere..."
    # Versuche apt
    apt-get install -y -qq age 2>/dev/null || {
      # Fallback: Binär von USB (falls vorhanden)
      if [ -f "${USB_MOUNT}/tools/age" ]; then
        install -m 755 "${USB_MOUNT}/tools/age" /usr/local/bin/age
        log_ok "age von USB-Tools installiert"
      else
        # Letzter Fallback: Download
        AGE_VER=$(curl -s "https://api.github.com/repos/FiloSottile/age/releases/latest" \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4 || echo "v1.1.1")
        curl -fsSLo /tmp/age.tar.gz \
          "https://github.com/FiloSottile/age/releases/download/${AGE_VER}/age-${AGE_VER}-linux-amd64.tar.gz"
        tar -xzf /tmp/age.tar.gz -C /tmp/
        install -m 755 /tmp/age/age /usr/local/bin/age
        rm -rf /tmp/age /tmp/age.tar.gz
        log_ok "age ${AGE_VER} heruntergeladen und installiert"
      fi
    }
  else
    log_ok "age bereits vorhanden ($(age --version 2>/dev/null | head -1))"
  fi
fi

# ── Phase 3: Layer 1 — Proxmox-Konfiguration wiederherstellen ────────────
log_section "Phase 3: Proxmox-Konfiguration (/etc/pve/)"
if [ "$AGE_KEY_OK" = "true" ]; then
  CONFIG_AGE=$(find "${BACKUP_BASE}/configs/" -name "*.tar.gz.age" 2>/dev/null | sort -r | head -1)
  if [ -n "$CONFIG_AGE" ]; then
    log "  Entschlüssle: $(basename "$CONFIG_AGE")..."
    age --decrypt -i /root/.age/key.txt "$CONFIG_AGE" > /tmp/config-restore.tar.gz

    mkdir -p /tmp/config-extract
    tar -xzf /tmp/config-restore.tar.gz -C /tmp/config-extract
    EXTRACTED=$(find /tmp/config-extract -name "backup-meta.txt" -exec dirname {} \; | head -1)

    # /etc/pve/nodes/ (LXC/VM Konfigurationen)
    if [ -d "${EXTRACTED}/pve/nodes" ]; then
      rsync -a "${EXTRACTED}/pve/nodes/" /etc/pve/nodes/ 2>/dev/null || true
      log_ok "/etc/pve/nodes/ (LXC/VM Configs) wiederhergestellt"
    fi

    # Netzwerk-Konfiguration
    if [ -f "${EXTRACTED}/network/interfaces" ]; then
      cp "${EXTRACTED}/network/interfaces" /etc/network/interfaces
      log_ok "/etc/network/interfaces wiederhergestellt"

      # Auto-NIC-Erkennung: bridge-ports auf aktiven NIC anpassen
      # Findet den ersten physischen NIC mit Carrier (Kabel eingesteckt)
      ACTIVE_NIC=""
      for nic in $(ls /sys/class/net/ 2>/dev/null | grep -vE '^(lo|vmbr|veth|wl|bond|dummy)'); do
        if [ "$(cat /sys/class/net/$nic/carrier 2>/dev/null)" = "1" ]; then
          ACTIVE_NIC="$nic"
          break
        fi
      done
      BRIDGE_NIC=$(awk '/bridge-ports/ && !/none/ {print $2; exit}' /etc/network/interfaces)
      if [ -n "$ACTIVE_NIC" ] && [ -n "$BRIDGE_NIC" ] && [ "$ACTIVE_NIC" != "$BRIDGE_NIC" ]; then
        sed -i "s/bridge-ports $BRIDGE_NIC/bridge-ports $ACTIVE_NIC/g" /etc/network/interfaces
        log_ok "Bridge-Port angepasst: $BRIDGE_NIC → $ACTIVE_NIC (Hardware-Unterschied erkannt)"
      elif [ -n "$ACTIVE_NIC" ]; then
        log_ok "Bridge-Port $BRIDGE_NIC ist aktiv (Carrier vorhanden)"
      else
        log_warn "Kein NIC mit Carrier gefunden — bridge-ports unverändert ($BRIDGE_NIC)"
      fi

      # Netzwerk neu laden
      ifreload -a 2>/dev/null || true
    fi

    # Meta-Info loggen
    if [ -f "${EXTRACTED}/backup-meta.txt" ]; then
      log "  Backup-Info:"
      grep -E "timestamp|hostname|proxmox_version|lxc_list" "${EXTRACTED}/backup-meta.txt" \
        | while read -r line; do log "    $line"; done
    fi

    rm -rf /tmp/config-restore.tar.gz /tmp/config-extract
    log_ok "Layer 1 Restore abgeschlossen"
  else
    log_warn "Kein Config-Backup (.tar.gz.age) auf USB gefunden"
    log_warn "  Erwartet in: ${BACKUP_BASE}/configs/"
  fi
else
  log_warn "Phase 3 übersprungen (kein age-Key)"
fi

# ── Phase 4: Backup-Storage registrieren ──────────────────────────────────
log_section "Phase 4: Proxmox Storage registrieren"
mkdir -p "${BACKUP_BASE}/dump"

if ! pvesm status 2>/dev/null | grep -q "openclaw-backup-usb"; then
  pvesm add dir openclaw-backup-usb \
    --path "$USB_MOUNT" \
    --content backup \
    --shared 0 2>/dev/null
  log_ok "Storage 'openclaw-backup-usb' registriert"
else
  log_ok "Storage 'openclaw-backup-usb' bereits vorhanden"
fi

# Ziel-Storage für Restore (wohin die Disk-Images gehen)
LXC_STORAGE="local-lvm"
if pvesm status 2>/dev/null | grep -q "^local-zfs"; then
  LXC_STORAGE="local-zfs"
  log "  Restore-Ziel: local-zfs"
elif pvesm status 2>/dev/null | grep -q "^local "; then
  LXC_STORAGE="local"
  log "  Restore-Ziel: local"
else
  log "  Restore-Ziel: local-lvm"
fi

DUMP_DIR="${BACKUP_BASE}/dump"
LXC_COUNT=$(ls "${DUMP_DIR}"/vzdump-lxc-*.tar.zst 2>/dev/null | wc -l || echo 0)
VM_COUNT=$(ls "${DUMP_DIR}"/vzdump-qemu-*.vma.zst 2>/dev/null | wc -l || echo 0)
log "  Gefunden: ${LXC_COUNT} LXC-Archive, ${VM_COUNT} VM-Archive"

# ── Phase 5: LXCs wiederherstellen ────────────────────────────────────────
log_section "Phase 5: LXC-Archive wiederherstellen (${LXC_COUNT} Container)"
for ARCHIVE in $(ls "${DUMP_DIR}"/vzdump-lxc-*.tar.zst 2>/dev/null | sort); do
  VMID=$(basename "$ARCHIVE" | sed 's/vzdump-lxc-\([0-9]*\)-.*/\1/')
  FNAME=$(basename "$ARCHIVE")
  log "  → LXC $VMID: $FNAME"

  # Vorhandene LXC bereinigen
  if pct status "$VMID" &>/dev/null; then
    pct stop "$VMID" --skiplock 2>/dev/null || true
    sleep 2
    pct destroy "$VMID" --purge 2>/dev/null || true
    log "    (bestehende LXC $VMID entfernt)"
  fi

  if pct restore "$VMID" "$ARCHIVE" \
    --storage "$LXC_STORAGE" \
    --unprivileged 1 \
    --start 0 2>>"$LOG_FILE"; then
    log_ok "LXC $VMID wiederhergestellt"
  else
    log_err "LXC $VMID: pct restore fehlgeschlagen — Log prüfen"
    RESTORE_ERRORS=$((RESTORE_ERRORS + 1))
  fi
done

# ── Phase 6: VMs wiederherstellen ─────────────────────────────────────────
log_section "Phase 6: VM-Archive wiederherstellen (${VM_COUNT} VMs)"
for ARCHIVE in $(ls "${DUMP_DIR}"/vzdump-qemu-*.vma.zst 2>/dev/null | sort); do
  VMID=$(basename "$ARCHIVE" | sed 's/vzdump-qemu-\([0-9]*\)-.*/\1/')
  FNAME=$(basename "$ARCHIVE")
  log "  → VM $VMID: $FNAME"

  if qm status "$VMID" &>/dev/null; then
    qm stop "$VMID" --skiplock 2>/dev/null || true
    sleep 2
    qm destroy "$VMID" --purge 2>/dev/null || true
  fi

  if qmrestore "$ARCHIVE" "$VMID" \
    --storage "$LXC_STORAGE" \
    --unique 0 2>>"$LOG_FILE"; then
    log_ok "VM $VMID wiederhergestellt"
  else
    log_err "VM $VMID: qmrestore fehlgeschlagen"
    RESTORE_ERRORS=$((RESTORE_ERRORS + 1))
  fi
done

# ── Phase 7: LXCs starten ─────────────────────────────────────────────────
log_section "Phase 7: LXCs starten (Infrastruktur zuerst)"
# Startreihenfolge: Netzwerk → Security → Services → Tools
PRIORITY_ORDER="110 115 125 120 170 104 108 130 210"

# Prioritäre LXCs geordnet starten
for VMID in $PRIORITY_ORDER; do
  if pct status "$VMID" &>/dev/null; then
    pct start "$VMID" 2>/dev/null && \
      log_ok "LXC $VMID gestartet" || \
      log_warn "LXC $VMID: Start fehlgeschlagen"
    sleep 2
  fi
done

# Verbleibende LXCs (z.B. CasaOS-Apps, VMs bleiben gestoppt)
for VMID in $(pct list 2>/dev/null | tail -n+2 | awk '{print $1}'); do
  echo "$PRIORITY_ORDER" | grep -qw "$VMID" && continue
  if pct status "$VMID" 2>/dev/null | grep -q "stopped"; then
    log "  LXC $VMID: gestoppt gelassen (manuell starten falls benötigt)"
  fi
done

log_ok "LXCs gestartet — warte 30s auf Service-Initialisierung..."
sleep 30

# ── Phase 8: App-Daten wiederherstellen ──────────────────────────────────
log_section "Phase 8: Layer 3 App-Daten wiederherstellen"

# Repo klonen falls noch nicht vorhanden
if [ ! -d "$REPO_DIR/.git" ]; then
  log "  Repo klonen..."
  git clone --quiet "$REPO_URL" "$REPO_DIR" 2>/dev/null || {
    log_warn "Repo-Clone fehlgeschlagen — App-Data-Restore übersprungen"
  }
fi

RESTORE_SCRIPT="${REPO_DIR}/scripts/backup/restore-appdata.sh"
if [ -f "$RESTORE_SCRIPT" ] && [ -d "${BACKUP_BASE}/appdata/" ]; then
  for SVC in headscale authentik n8n; do
    log "  → $SVC App-Daten..."
    bash "$RESTORE_SCRIPT" --service "$SVC" 2>>"$LOG_FILE" && \
      log_ok "$SVC App-Daten wiederhergestellt" || \
      log_warn "$SVC: App-Data-Restore fehlgeschlagen (Service läuft?)"
  done
else
  log_warn "App-Data-Restore übersprungen (kein Repo oder keine appdata/ auf USB)"
fi

# ── Abschluss ─────────────────────────────────────────────────────────────
log_section "Disaster Recovery abgeschlossen"
PROXMOX_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v 127 | head -1)

log ""
if [ "$RESTORE_ERRORS" -eq 0 ]; then
  log "  ✓ ALLE LXCs/VMs erfolgreich wiederhergestellt"
else
  log "  ⚠  $RESTORE_ERRORS Fehler aufgetreten — Logs prüfen: $LOG_FILE"
fi

log ""
log "  Proxmox Web-UI: https://${PROXMOX_IP}:8006"
log "  SSH:            ssh root@${PROXMOX_IP}"
log "  Logs:           journalctl -u openclaw-first-boot -f"
log "  Backup-Source:  $DUMP_DIR"
log ""
log "  Wiederhergestellte Container:"
pct list 2>/dev/null | while read -r line; do log "    $line"; done
log ""
log "  Nächste Schritte:"
log "    1. Proxmox Web-UI prüfen (alle LXCs laufend?)"
log "    2. Nextcloud: falls benötigt → bash ${REPO_DIR}/scripts/install-lxc-nextcloud.sh"
log "    3. Headscale: Clients re-authentifizieren (tailscale login)"
log "    4. age-Key sicher aufbewahren: /root/.age/key.txt + Passwort-Manager"
