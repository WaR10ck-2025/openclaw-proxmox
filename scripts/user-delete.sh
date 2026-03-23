#!/bin/bash
# user-delete.sh — User + alle Ressourcen entfernen
#
# Verwendung:
#   ./user-delete.sh <user_id>
#
# Entfernt: LXCs, ZFS-Datasets, Bridge, iptables-Regeln

set -e

USER_ID="${1:?Verwendung: $0 <user_id>}"
BRIDGE_URL="${BRIDGE_URL:-http://192.168.10.141:8200}"
ADMIN_KEY="${ADMIN_KEY:?ADMIN_KEY muss gesetzt sein}"

# Status prüfen
STATUS=$(curl -s "${BRIDGE_URL}/admin/users/${USER_ID}/status" \
  -H "X-API-Key: ${ADMIN_KEY}" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(f'{d[\"username\"]} ({d[\"status\"]})')" \
  2>/dev/null || echo "unbekannt")

echo "► User $USER_ID löschen: $STATUS"
echo -n "  Sicher? (ja/nein): "
read CONFIRM

if [ "$CONFIRM" != "ja" ]; then
  echo "  Abgebrochen."
  exit 0
fi

echo ""
echo "► Lösche User $USER_ID + alle Ressourcen..."
RESULT=$(curl -s -w "\n%{http_code}" -X DELETE \
  "${BRIDGE_URL}/admin/users/${USER_ID}" \
  -H "X-API-Key: ${ADMIN_KEY}")

HTTP_CODE=$(echo "$RESULT" | tail -1)
BODY=$(echo "$RESULT" | head -n -1)

if [ "$HTTP_CODE" != "200" ]; then
  echo "✗ Fehler (HTTP $HTTP_CODE):"
  echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
  exit 1
fi

echo "✓ User $USER_ID vollständig entfernt"
echo "$BODY" | python3 -m json.tool 2>/dev/null || echo "$BODY"
