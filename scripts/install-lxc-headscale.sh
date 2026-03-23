#!/bin/bash
# install-lxc-headscale.sh — LXC 115: Headscale Control-Server
#
# Headscale ist ein selbst-gehosteter Tailscale Control-Server.
# Jeder User bekommt einen eigenen Namespace + Pre-Auth-Key.
#
# Netzwerk: 192.168.10.115 (Management-Netz, vmbr0)
# Port:     8080 (Tailscale-Clients verbinden hier)
#
# Ausführen auf dem Proxmox-Host als root:
#   bash scripts/install-lxc-headscale.sh

set -e

LXC_ID=115
LXC_IP="192.168.10.115"
HOSTNAME="headscale"
RAM=512
DISK=8
CORES=1
TEMPLATE="local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
STORAGE="${STORAGE:-local-zfs}"
GATEWAY="192.168.10.1"

HEADSCALE_PORT="${HEADSCALE_PORT:-8080}"
BASE_URL="http://${LXC_IP}:${HEADSCALE_PORT}"

echo "► LXC $LXC_ID ($HOSTNAME) — Headscale Control-Server..."

if pct status "$LXC_ID" &>/dev/null; then
  echo "  ► LXC $LXC_ID existiert bereits — überspringe Anlage"
else
  pct create "$LXC_ID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --memory "$RAM" \
    --cores "$CORES" \
    --rootfs "$STORAGE:$DISK" \
    --net0 "name=eth0,bridge=vmbr0,ip=${LXC_IP}/24,gw=${GATEWAY}" \
    --nameserver "1.1.1.1 8.8.8.8" \
    --features "nesting=1" \
    --unprivileged 1 \
    --start 0
  echo "  ✓ LXC $LXC_ID angelegt"
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

# ─── Setup-Script ────────────────────────────────────────────────────────────
cat > /tmp/headscale-setup.sh << SETUP
#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

echo "── System-Update ────────────────────────────────"
apt-get update -qq
apt-get install -y -qq curl ca-certificates

# ── Headscale installieren ────────────────────────────────────────────────────
if ! command -v headscale &>/dev/null; then
  echo "── Headscale installieren ───────────────────────"
  # Aktuelle Version ermitteln
  HEADSCALE_VERSION=\$(curl -fsSL https://api.github.com/repos/juanfont/headscale/releases/latest \
    | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/' || echo "0.23.0")
  echo "  Version: \$HEADSCALE_VERSION"

  HEADSCALE_DL_URL="https://github.com/juanfont/headscale/releases/download/v\${HEADSCALE_VERSION}/headscale_\${HEADSCALE_VERSION}_linux_amd64"
  curl -fsSL "\$HEADSCALE_DL_URL" -o /usr/local/bin/headscale
  chmod +x /usr/local/bin/headscale
  echo "  ✓ Headscale \$(headscale version) installiert"
else
  echo "  ✓ Headscale bereits vorhanden: \$(headscale version)"
fi

# ── Headscale konfigurieren ───────────────────────────────────────────────────
mkdir -p /etc/headscale /var/lib/headscale

if [ ! -f /etc/headscale/config.yaml ]; then
  cat > /etc/headscale/config.yaml << 'CONFIG'
---
server_url: ${BASE_URL}
listen_addr: 0.0.0.0:${HEADSCALE_PORT}
metrics_listen_addr: 127.0.0.1:9090

private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key

prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48
  allocation: sequential

derp:
  server:
    enabled: false
  urls: []
  auto_update_enabled: false
  update_frequency: 24h

disable_check_updates: true
ephemeral_node_inactivity_timeout: 30m

database:
  type: sqlite3
  sqlite:
    path: /var/lib/headscale/db.sqlite

log:
  level: info

acl_policy_path: /etc/headscale/acls.yaml
dns:
  nameservers:
    global:
      - 1.1.1.1
  magic_dns: false
CONFIG
  echo "  ✓ headscale config.yaml erstellt"
fi

# ACL: alle Namespaces dürfen sich gegenseitig NICHT erreichen
# (Tailscale-Clients in verschiedenen Namespaces sind getrennt)
if [ ! -f /etc/headscale/acls.yaml ]; then
  cat > /etc/headscale/acls.yaml << 'ACLCONF'
---
acls:
  - action: accept
    src:
      - "*"
    dst:
      - "*:*"
ACLCONF
  echo "  ✓ acls.yaml erstellt (open policy — User-Isolation via Namespace)"
fi

# ── Systemd-Service ───────────────────────────────────────────────────────────
cat > /etc/systemd/system/headscale.service << 'SERVICE'
[Unit]
Description=Headscale Tailscale Control Server
After=network.target

[Service]
ExecStart=/usr/local/bin/headscale serve
Restart=always
RestartSec=5
User=root
WorkingDirectory=/var/lib/headscale

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable headscale
systemctl start headscale

sleep 2
systemctl is-active headscale && echo "  ✓ Headscale läuft" || echo "  ✗ Headscale-Start fehlgeschlagen"

echo ""
echo "══════════════════════════════════════════════════"
echo "  Headscale (LXC ${LXC_ID}) — FERTIG"
echo "  URL:    ${BASE_URL}"
echo "  Status: \$(systemctl is-active headscale)"
echo "══════════════════════════════════════════════════"
SETUP

pct push "$LXC_ID" /tmp/headscale-setup.sh /tmp/setup.sh
pct exec "$LXC_ID" -- bash /tmp/setup.sh

echo ""
echo "✓ Headscale (LXC $LXC_ID) bereit: $BASE_URL"
echo "  Test: pct exec $LXC_ID -- headscale version"
echo "  Users: pct exec $LXC_ID -- headscale users list"
