#!/bin/bash
# user-status.sh — Detaillierter User-Status + Zugangsdaten
#
# Verwendung:
#   ./user-status.sh <user_id>

USER_ID="${1:?Verwendung: $0 <user_id>}"
BRIDGE_URL="${BRIDGE_URL:-http://192.168.10.141:8200}"
ADMIN_KEY="${ADMIN_KEY:?ADMIN_KEY muss gesetzt sein}"

RESULT=$(curl -s "${BRIDGE_URL}/admin/users/${USER_ID}/status" \
  -H "X-API-Key: ${ADMIN_KEY}")

echo "$RESULT" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'═══ User {d[\"user_id\"]}: {d[\"username\"]} ═══════════════════════════════')
print(f'  Status:        {d[\"status\"]}')
if d.get('provisioning_step'):
    print(f'  Schritt:       {d[\"provisioning_step\"]}')
print(f'  CasaOS-URL:    {d.get(\"casaos_url\") or \"—\"}')
print(f'  Bridge:        {d[\"bridge\"]}')
print(f'  Subnetz:       {d[\"subnet\"]}')
print(f'  ZFS-Dataset:   {d.get(\"zfs_dataset\") or \"—\"}')
print(f'  ZFS-Quota:     {d.get(\"zfs_quota\") or \"—\"}')
print()

smb = d.get('smb_shares')
if smb:
    print(f'  SMB-Shares:')
    print(f'    Files:   {smb[\"files\"]}')
    print(f'    AppData: {smb[\"appdata\"]}')
    print(f'    User:    {smb[\"user\"]}')
    print(f'    Passwort: {smb[\"password\"]}')
    print()

vpn = d.get('vpn')
if vpn:
    print(f'  VPN (Tailscale via Headscale):')
    print(f'    Server:    {vpn[\"headscale_url\"]}')
    print(f'    Namespace: {vpn[\"namespace\"]}')
    print(f'    Verbinden: {vpn[\"connect_hint\"]}')
    print()

print(f'  API-Key:       {d[\"api_key\"]}')
print('═══════════════════════════════════════════════════════════════')
"
