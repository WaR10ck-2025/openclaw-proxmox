#!/bin/bash
# user-list.sh — Alle Tenants anzeigen
#
# Verwendung:
#   ./user-list.sh

BRIDGE_URL="${BRIDGE_URL:-http://192.168.10.141:8200}"
ADMIN_KEY="${ADMIN_KEY:?ADMIN_KEY muss gesetzt sein}"

RESULT=$(curl -s "${BRIDGE_URL}/admin/users" -H "X-API-Key: ${ADMIN_KEY}")

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
users = d.get('users', [])
print(f'═══ Tenants ({d[\"count\"]}) ════════════════════════════════════════')
if not users:
    print('  Keine User angelegt.')
for u in users:
    status_icon = '✓' if u['status'] == 'ready' else ('⚙' if u['status'] == 'provisioning' else '✗')
    print(f'  {status_icon} [{u[\"user_id\"]}] {u[\"username\"]:20} | {u[\"subnet\"]:18} | {u.get(\"casaos_url\") or \"—\":25} | {u[\"status\"]}')
    if u['status'] not in ('ready', 'provisioning'):
        step = u.get('provisioning_step', '')
        if step:
            print(f'      Schritt: {step}')
print('═══════════════════════════════════════════════════════════════')
print()
print('Befehle:')
print('  Anlegen:  ADMIN_KEY=\$ADMIN_KEY ./user-create.sh <name> [quota]')
print('  Status:   ADMIN_KEY=\$ADMIN_KEY ./user-status.sh <user_id>')
print('  Löschen:  ADMIN_KEY=\$ADMIN_KEY ./user-delete.sh <user_id>')
"
