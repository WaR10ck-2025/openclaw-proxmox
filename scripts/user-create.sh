#!/bin/bash
# user-create.sh — Neuen User via Admin-API anlegen
#
# Verwendung:
#   ./user-create.sh <username> [quota]
#   ./user-create.sh alice
#   ./user-create.sh alice 50G
#
# Voraussetzungen:
#   - BRIDGE_URL in Umgebung oder als Default-Wert
#   - ADMIN_KEY in Umgebung (aus .env)

set -e

USERNAME="${1:?Verwendung: $0 <username> [quota]}"
QUOTA="${2:-100G}"
BRIDGE_URL="${BRIDGE_URL:-http://192.168.10.141:8200}"
ADMIN_KEY="${ADMIN_KEY:?ADMIN_KEY muss gesetzt sein (aus .env)}"

echo "► User anlegen: '$USERNAME' (Quota: $QUOTA)"
echo "  Bridge: $BRIDGE_URL"
echo ""

RESULT=$(curl -s -w "\n%{http_code}" -X POST \
  "${BRIDGE_URL}/admin/users?username=${USERNAME}&quota=${QUOTA}" \
  -H "X-API-Key: ${ADMIN_KEY}" \
  -H "Content-Type: application/json")

HTTP_CODE=$(echo "$RESULT" | tail -1)
BODY=$(echo "$RESULT" | head -n -1)

if [ "$HTTP_CODE" != "200" ]; then
  echo "✗ Fehler (HTTP $HTTP_CODE):"
  echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
  exit 1
fi

echo "✓ User angelegt!"
echo ""
echo "$BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(f'  User-ID:     {d[\"user_id\"]}')
print(f'  Username:    {d[\"username\"]}')
print(f'  API-Key:     {d[\"api_key\"]}')
print(f'  Bridge:      {d.get(\"bridge\", \"?\")}')
print(f'  Subnetz:     {d.get(\"subnet\", \"?\")}')
print(f'  CasaOS-URL:  {d.get(\"casaos_url\") or \"(wird provisioniert)\" }')
print(f'  Status:      {d[\"status\"]}')
print()
print('  Provisionierung läuft (~5–10 Min) — Status prüfen mit:')
print(f'  ./user-status.sh {d[\"user_id\"]}')
"
