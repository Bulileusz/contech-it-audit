#!/usr/bin/env bash
# Testy dymne API karty rozeznania IT.
#
# Użycie:
#   API=https://<worker>.workers.dev ORIGIN=https://bulileusz.github.io ADMIN_KEY=... bash test/smoke.sh
#   (lokalnie: API=http://localhost:8787 ORIGIN=http://localhost:8788 ADMIN_KEY=<z .dev.vars>)
#
# Opcje:
#   RATE_TEST=1   dodatkowo sprawdza limit 60 żądań / 10 min (zużywa limit dla Twojego IP).
#
# Skrypt wypisuje tylko PASS/FAIL. Nigdy nie drukuje treści eksportu ani payloadów,
# więc może działać także w CI publicznego repozytorium.
# Rekordy testowe mają firmę "SMOKE-TEST ..." i można je usunąć poleceniem z README.
set -u

API="${API:-http://localhost:8787}"
API="${API%/}"
ORIGIN="${ORIGIN:-https://bulileusz.github.io}"
ADMIN_KEY="${ADMIN_KEY:-}"
FOREIGN="https://obcy-origin.example"

PASS=0; FAIL=0; SKIP=0
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

ok()   { PASS=$((PASS+1)); printf 'PASS  %s\n' "$1"; }
ko()   { FAIL=$((FAIL+1)); printf 'FAIL  %s  -> %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf 'SKIP  %s  -> %s\n' "$1" "$2"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else ko "$1" "oczekiwano: $2, jest: $3"; fi; }

uuid() {
  if command -v uuidgen >/dev/null 2>&1; then uuidgen | tr 'A-Z' 'a-z'
  elif command -v python3 >/dev/null 2>&1; then python3 -c 'import uuid;print(uuid.uuid4())'
  else node -e 'console.log(require("crypto").randomUUID())'; fi
}

# body <id> <company> <answered> <website>
body() {
cat <<JSON
{"id":"$1","website":"$4","company":"$2","filler":"Smoke Test","phone":"000 000 000","answered":$3,
 "payload":{"v":1,"meta":{"company":"$2","filler":"Smoke Test","phone":"000 000 000","date":"2026-01-01"},
  "answered":$3,"answered_all":$3,"total_required":39,
  "answers":[
   {"id":"q1","n":1,"sec":"A. Ludzie i skala","q":"Ile osób łącznie pracuje w firmie?","t":"radio","opt":false,"v":"4–9"},
   {"id":"q12","n":12,"sec":"C. Pliki i dane","q":"Gdzie trzymane są pliki firmowe?","t":"multi","opt":false,"v":["Google Drive","Dropbox"]},
   {"id":"q36","n":36,"sec":"G. Co realnie boli","q":"Które trzy czynności biurowe zajmują najwięcej czasu?","t":"textarea","opt":false,"v":"Zażółć gęślą jaźń; \"cytat\"\nnowa linia"},
   {"id":"q37","n":37,"sec":"G. Co realnie boli","q":"Co robicie co tydzień albo co miesiąc dokładnie tak samo?","t":"textarea","opt":false,"v":"=SUMA(A1:A9) próba formuły"}
  ]}}
JSON
}

# post <path> <origin> <plik> -> kod HTTP; body w $TMP/out
post() {
  curl -sS -o "$TMP/out" -w '%{http_code}' -X POST "$API$1" \
    -H "Origin: $2" -H "Content-Type: application/json" --data-binary @"$3"
}
# export_json <status|""> -> kod HTTP; body w $TMP/export
export_json() {
  local q="format=json"; [ -n "$1" ] && q="$q&status=$1"
  curl -sS -o "$TMP/export" -w '%{http_code}' "$API/export?$q" -H "Authorization: Bearer $ADMIN_KEY"
}
has_id()      { grep -q "\"id\":\"$1\"" "$TMP/export"; }
has_company() { grep -q "\"company\":\"$1\"" "$TMP/export"; }

echo "API=$API"
echo "ORIGIN=$ORIGIN"
echo

# 0. health
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/")
check "GET / odpowiada 200" "200" "$code"

A="$(uuid)"; B="$(uuid)"; C="$(uuid)"

# 1. draft tworzy rekord
body "$A" "SMOKE-TEST A1" 1 "" > "$TMP/a1.json"
code=$(post /draft "$ORIGIN" "$TMP/a1.json")
check "POST /draft tworzy rekord (200)" "200" "$code"
grep -q '"status":"draft"' "$TMP/out" && ok "POST /draft zwraca status draft" || ko "POST /draft zwraca status draft" "brak status draft w odpowiedzi"

# 2. drugi draft z tym samym id aktualizuje
body "$A" "SMOKE-TEST A2" 2 "" > "$TMP/a2.json"
code=$(post /draft "$ORIGIN" "$TMP/a2.json")
check "POST /draft (ten sam id) aktualizuje (200)" "200" "$code"
if [ -n "$ADMIN_KEY" ]; then
  code=$(export_json draft)
  if [ "$code" = "200" ] && has_id "$A" && has_company "SMOKE-TEST A2" && ! has_company "SMOKE-TEST A1"; then
    ok "eksport: rekord A ma zaktualizowane dane, bez duplikatu"
  else ko "eksport: rekord A ma zaktualizowane dane, bez duplikatu" "kod $code lub zła treść"; fi
else skip "eksport: weryfikacja aktualizacji szkicu" "brak ADMIN_KEY"; fi

# 3. submit ustawia final
code=$(post /submit "$ORIGIN" "$TMP/a2.json")
check "POST /submit odpowiada 200" "200" "$code"
grep -q '"ok":true' "$TMP/out" && grep -q '"status":"final"' "$TMP/out" \
  && ok "POST /submit zwraca ok:true i status final" || ko "POST /submit zwraca ok:true i status final" "zła odpowiedź"

# 4. draft po final nie nadpisuje
body "$A" "SMOKE-TEST A3" 3 "" > "$TMP/a3.json"
code=$(post /draft "$ORIGIN" "$TMP/a3.json")
check "POST /draft po final odpowiada 200" "200" "$code"
grep -q '"status":"final"' "$TMP/out" && ok "POST /draft po final zgłasza status final" || ko "POST /draft po final zgłasza status final" "zła odpowiedź"
if [ -n "$ADMIN_KEY" ]; then
  code=$(export_json final)
  if [ "$code" = "200" ] && has_id "$A" && has_company "SMOKE-TEST A2" && ! has_company "SMOKE-TEST A3"; then
    ok "eksport: rekord final nie został nadpisany szkicem"
  else ko "eksport: rekord final nie został nadpisany szkicem" "kod $code lub zła treść"; fi
else skip "eksport: weryfikacja ochrony rekordu final" "brak ADMIN_KEY"; fi

# 5. obcy origin
code=$(post /draft "$FOREIGN" "$TMP/a1.json")
check "POST z obcego origin dostaje 403" "403" "$code"

# 6. preflight
curl -sS -o /dev/null -D "$TMP/pre.h" -w '%{http_code}' -X OPTIONS "$API/draft" \
  -H "Origin: $ORIGIN" -H "Access-Control-Request-Method: POST" \
  -H "Access-Control-Request-Headers: content-type" > "$TMP/pre.code"
code=$(cat "$TMP/pre.code")
check "OPTIONS preflight odpowiada 204" "204" "$code"
tr -d '\r' < "$TMP/pre.h" | tr 'A-Z' 'a-z' > "$TMP/pre.l"
grep -q "^access-control-allow-origin: $(printf '%s' "$ORIGIN" | tr 'A-Z' 'a-z')$" "$TMP/pre.l" \
  && ok "preflight: Access-Control-Allow-Origin = ORIGIN" || ko "preflight: Access-Control-Allow-Origin = ORIGIN" "brak lub inny origin"
grep -q '^access-control-allow-methods:.*post' "$TMP/pre.l" \
  && ok "preflight: Allow-Methods zawiera POST" || ko "preflight: Allow-Methods zawiera POST" "brak"
grep -q '^access-control-allow-headers:.*content-type' "$TMP/pre.l" \
  && ok "preflight: Allow-Headers zawiera Content-Type" || ko "preflight: Allow-Headers zawiera Content-Type" "brak"
grep -q '^access-control-max-age:' "$TMP/pre.l" \
  && ok "preflight: Max-Age ustawiony" || ko "preflight: Max-Age ustawiony" "brak"
code=$(curl -sS -o /dev/null -w '%{http_code}' -X OPTIONS "$API/draft" -H "Origin: $FOREIGN" -H "Access-Control-Request-Method: POST")
check "OPTIONS z obcego origin dostaje 403" "403" "$code"

# 7. export: auth
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/export?format=csv")
check "GET /export bez tokenu -> 401" "401" "$code"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/export?format=csv" -H "Authorization: Bearer zly-klucz")
check "GET /export ze złym tokenem -> 401" "401" "$code"

if [ -n "$ADMIN_KEY" ]; then
  code=$(curl -sS -o "$TMP/export.csv" -D "$TMP/csv.h" -w '%{http_code}' "$API/export?format=csv" -H "Authorization: Bearer $ADMIN_KEY")
  check "GET /export?format=csv z tokenem -> 200" "200" "$code"
  bom=$(head -c 3 "$TMP/export.csv" | od -An -tx1 | tr -d ' \n')
  check "CSV zaczyna się od BOM UTF-8" "efbbbf" "$bom"
  tr -d '\r' < "$TMP/csv.h" | tr 'A-Z' 'a-z' | grep -q '^content-type: text/csv' \
    && ok "CSV: Content-Type text/csv" || ko "CSV: Content-Type text/csv" "inny nagłówek"
  head -1 "$TMP/export.csv" | grep -q ';status;created_at;' \
    && ok "CSV: separator średnik w nagłówku" || ko "CSV: separator średnik w nagłówku" "brak"
  grep -q $'\r$' "$TMP/export.csv" && ok "CSV: końce linii CRLF" || ko "CSV: końce linii CRLF" "brak CR"
  grep -q 'Zażółć gęślą jaźń' "$TMP/export.csv" && ok "CSV: polskie znaki zachowane (UTF-8)" || ko "CSV: polskie znaki zachowane" "brak"
  grep -q "'=SUMA" "$TMP/export.csv" && ok "CSV: neutralizacja formuł (=...) apostrofem" || ko "CSV: neutralizacja formuł" "brak apostrofu"
  grep -q 'Google Drive | Dropbox' "$TMP/export.csv" && ok "CSV: odpowiedzi wielokrotne złączone ' | '" || ko "CSV: odpowiedzi wielokrotne" "brak"
  grep -q '1\. Ile osób łącznie pracuje w firmie?' "$TMP/export.csv" && ok "CSV: nagłówki kolumn z treścią pytań" || ko "CSV: nagłówki kolumn z treścią pytań" "brak"
  head -1 "$TMP/export.csv" | grep -q "$(printf 'id\xef\xbb\xbf')" && ko "CSV: BOM tylko na początku" "BOM w środku" || ok "CSV: BOM tylko na początku pliku"
else skip "GET /export?format=csv (BOM, średnik, UTF-8)" "brak ADMIN_KEY"; fi

# 8. body 200 KB
{ printf '{"id":"%s","website":"","payload":{"meta":{},"answers":[],"x":"' "$B"; head -c 200000 /dev/zero | tr '\0' 'a'; printf '"}}'; } > "$TMP/big.json"
code=$(post /draft "$ORIGIN" "$TMP/big.json")
check "Body 200 KB odrzucone (413)" "413" "$code"
# to samo bez Content-Length (chunked)
code=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "$API/draft" -H "Origin: $ORIGIN" \
  -H "Content-Type: application/json" -H "Transfer-Encoding: chunked" --data-binary @"$TMP/big.json")
check "Body 200 KB (chunked, bez Content-Length) odrzucone (413)" "413" "$code"

# 9. honeypot
body "$C" "SMOKE-TEST HONEYPOT" 1 "http://spam.example" > "$TMP/hp.json"
code=$(post /draft "$ORIGIN" "$TMP/hp.json")
check "Honeypot niepusty -> 200" "200" "$code"
if [ -n "$ADMIN_KEY" ]; then
  code=$(export_json "")
  if [ "$code" = "200" ] && ! has_id "$C"; then ok "Honeypot: brak rekordu w bazie"; else ko "Honeypot: brak rekordu w bazie" "rekord istnieje lub kod $code"; fi
else skip "Honeypot: weryfikacja braku rekordu" "brak ADMIN_KEY"; fi

# 10. walidacja
printf 'to nie jest json' > "$TMP/bad.json"
code=$(post /draft "$ORIGIN" "$TMP/bad.json")
check "Niepoprawny JSON -> 400" "400" "$code"
printf '{"id":"nie-uuid","payload":{}}' > "$TMP/badid.json"
code=$(post /draft "$ORIGIN" "$TMP/badid.json")
check "Niepoprawny id -> 400" "400" "$code"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/draft" -H "Origin: $ORIGIN")
check "GET /draft -> 405" "405" "$code"
code=$(curl -sS -o /dev/null -w '%{http_code}' "$API/nie-ma" -H "Origin: $ORIGIN")
check "Nieznana ścieżka -> 404" "404" "$code"

# 11. rate limit (opcjonalnie)
if [ "${RATE_TEST:-0}" = "1" ]; then
  last=""
  for i in $(seq 1 70); do last=$(curl -sS -o /dev/null -w '%{http_code}' "$API/export"); [ "$last" = "429" ] && break; done
  check "Rate limit: po >60 żądaniach 429" "429" "$last"
else skip "Rate limit 60/10 min" "ustaw RATE_TEST=1"; fi

echo
echo "Wynik: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
