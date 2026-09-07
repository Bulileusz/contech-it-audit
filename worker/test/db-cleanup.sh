#!/usr/bin/env bash
# Usuwanie rekordów z produkcyjnej bazy D1 przez REST API Cloudflare (bez wranglera).
#
# Tryby (zmienna MODE):
#   smoke   usuwa rekordy testowe: company LIKE 'SMOKE-TEST%'   (domyślny)
#   id      usuwa jedno zgłoszenie o UUID podanym w TARGET_ID (np. prośba klienta o usunięcie danych)
#
# Wymaga: CLOUDFLARE_API_TOKEN (uprawnienie D1:Edit), opcjonalnie CLOUDFLARE_ACCOUNT_ID.
# Użycie lokalne:
#   CLOUDFLARE_API_TOKEN=... MODE=smoke bash worker/test/db-cleanup.sh
#   CLOUDFLARE_API_TOKEN=... MODE=id TARGET_ID=<uuid> bash worker/test/db-cleanup.sh
# Skrypt nie wypisuje treści rekordów, tylko liczbę usuniętych wierszy.
set -euo pipefail

D1_NAME="${D1_NAME:-contech-it-audit}"
MODE="${MODE:-smoke}"
TARGET_ID="${TARGET_ID:-}"
API="https://api.cloudflare.com/client/v4"

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || { echo "::error::Brak CLOUDFLARE_API_TOKEN"; exit 1; }
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN")

ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-}"
if [ -z "$ACCOUNT_ID" ]; then
  ACCOUNT_ID=$(curl -sS "$API/accounts" "${auth[@]}" | jq -r '.result[0].id // empty')
fi
[ -n "$ACCOUNT_ID" ] || { echo "::error::Nie udało się ustalić konta Cloudflare"; exit 1; }

DB_ID=$(curl -sS "$API/accounts/$ACCOUNT_ID/d1/database?name=$D1_NAME&per_page=100" "${auth[@]}" \
  | jq -r --arg n "$D1_NAME" '.result[]? | select(.name == $n) | .uuid' | head -1)
[ -n "$DB_ID" ] || { echo "::error::Baza $D1_NAME nie istnieje na tym koncie"; exit 1; }

case "$MODE" in
  smoke)
    SQL="DELETE FROM submissions WHERE company LIKE 'SMOKE-TEST%'" ;;
  id)
    if ! printf '%s' "$TARGET_ID" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
      echo "::error::TARGET_ID musi być UUID zgłoszenia"; exit 1
    fi
    SQL="DELETE FROM submissions WHERE id = '$(printf '%s' "$TARGET_ID" | tr 'A-F' 'a-f')'" ;;
  *)
    echo "::error::Nieznany tryb: $MODE (dozwolone: smoke, id)"; exit 1 ;;
esac

resp=$(curl -sS -X POST "$API/accounts/$ACCOUNT_ID/d1/database/$DB_ID/query" "${auth[@]}" \
  -H "Content-Type: application/json" --data "$(jq -cn --arg sql "$SQL" '{sql:$sql}')")
echo "$resp" | jq -e '.success == true' > /dev/null || { echo "::error::D1 query: $(echo "$resp" | jq -c '.errors')"; exit 1; }
echo "Tryb: $MODE. Usunięte rekordy: $(echo "$resp" | jq -r '.result[0].meta.changes // 0')"
