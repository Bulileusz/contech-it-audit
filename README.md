# Karta rozeznania IT dla małej firmy budowlanej

Jednoplikowy formularz HTML (43 pytania w 7 sekcjach) wystawiony na GitHub Pages
plus lekki backend na Cloudflare Workers + D1, który zbiera odpowiedzi do bazy.

- Formularz działa na telefonie, zapisuje postęp lokalnie (localStorage) i w tle na serwerze,
  nie gubi danych przy braku sieci i ma awaryjną drogę e-mailową (schowek, plik, PDF).
- Backend: `POST /draft` (szkice w tle), `POST /submit` (wysyłka końcowa),
  `GET /export` (CSV/JSON tylko z kluczem administratora).
- Zero zależności zewnętrznych w kliencie, brak bundlera, brak fontów z CDN.

## Struktura repozytorium

```
.
├── docs/                         # GitHub Pages (gałąź main, katalog /docs)
│   ├── index.html                # cały formularz: HTML + CSS + JS w jednym pliku
│   └── .nojekyll                 # wyłącza Jekyll na Pages
├── worker/                       # backend Cloudflare Worker
│   ├── src/index.js              # endpointy, CORS, rate limit, honeypot, eksport CSV/JSON
│   ├── schema.sql                # tabele: submissions, rate_limits
│   ├── wrangler.toml             # konfiguracja workera i bindingu D1 (bez sekretów)
│   ├── package.json              # skrypty npm (dev, deploy, migracje, testy)
│   ├── .dev.vars.example         # wzór lokalnych zmiennych (kopiuj do .dev.vars, ignorowany przez git)
│   └── test/
│       ├── smoke.sh              # testy dymne API (curl)
│       └── db-cleanup.sh         # usuwanie rekordów testowych lub zgłoszenia po UUID (REST API D1)
├── .github/workflows/
│   ├── deploy-worker.yml         # deploy workera bez logowania interaktywnego (token API)
│   ├── smoke-test.yml            # ręczne testy dymne na wdrożonym API, sprzątają po sobie
│   └── db-cleanup.yml            # ręczne czyszczenie bazy: rekordy testowe albo zgłoszenie po UUID
├── .gitignore                    # .dev.vars, .wrangler, node_modules, *.csv
└── README.md
```

## Jak to działa

1. Klient przy pierwszym wejściu generuje `crypto.randomUUID()` i trzyma go w localStorage.
   Odświeżenie strony nie tworzy nowego rekordu.
2. Każda zmiana zapisuje pełny stan lokalnie (debounce 400 ms). Po powrocie stan jest
   odtwarzany, a nad formularzem pojawia się pasek z informacją i przyciskiem
   „Wyczyść i zacznij od nowa”.
3. Co 10 s od ostatniej zmiany klient wysyła `POST /draft`. Przy ukryciu karty
   (`visibilitychange`, `pagehide`) używa `navigator.sendBeacon`. Błędy sieci są ciche:
   w pasku postępu widać tylko „Zapisano HH:MM” albo „Brak połączenia, odpowiedzi zapisane lokalnie”.
4. „Wyślij odpowiedzi” robi `POST /submit`. Po sukcesie formularz przechodzi w tryb tylko
   do odczytu i pokazuje numer zgłoszenia (8 pierwszych znaków UUID). Po błędzie pokazuje,
   co zrobić, a przyciski kopiowania i pobierania zostają jako droga awaryjna.
   localStorage jest czyszczony wyłącznie po potwierdzeniu przez użytkownika.
5. Serwer: `POST /draft` to upsert po `id` ze statusem `draft`, który nie nadpisuje rekordu
   `final`. `POST /submit` to upsert ze statusem `final`. Body powyżej 128 KB dostaje 413,
   niepuste pole `website` (honeypot) dostaje 200 bez zapisu, powyżej 60 żądań na 10 minut
   z jednego `ip_hash` leci 429. IP trafia do bazy tylko jako SHA-256 z solą.
   Payload i IP nie są logowane.

Ustawienia klienta są w jednym miejscu, w bloku `CONFIG` na początku `<script>`
w `docs/index.html`: `ENDPOINT`, `DRAFT_DEBOUNCE_MS`, `LOCAL_DEBOUNCE_MS`,
`REQUEST_TIMEOUT_MS`, `STORAGE_KEY`. Pusty `ENDPOINT` (albo otwarcie z pliku lokalnego)
przełącza formularz w tryb bez serwera: zapis tylko w przeglądarce, przekazanie odpowiedzi e-mailem.

## Wdrożenie

### Wariant A: GitHub Actions (bez instalowania czegokolwiek, da się zrobić z telefonu)

1. **Token Cloudflare**: dash.cloudflare.com → Manage Account → Account API Tokens →
   Create Token → szablon „Edit Cloudflare Workers” → dodaj uprawnienie
   *Account → D1 → Edit* → Continue → Create Token. Skopiuj token.
2. **Sekrety repozytorium** (GitHub → Settings → Secrets and variables → Actions → New repository secret):
   - `CLOUDFLARE_API_TOKEN`: token z punktu 1,
   - `ADMIN_KEY`: własny długi losowy ciąg (minimum 24 znaki), to hasło do eksportu danych,
   - opcjonalnie `CLOUDFLARE_ACCOUNT_ID` (tylko gdy token widzi więcej niż jedno konto),
   - opcjonalnie `HASH_SALT` (gdy brak, workflow generuje losową sól przy pierwszym deployu).
3. **Uruchom workflow**: Actions → „Deploy worker” → Run workflow. Workflow tworzy bazę D1
   (jeśli nie istnieje), wgrywa schemat, deployuje workera, ustawia sekrety i **wpisuje adres
   workera do `CONFIG.ENDPOINT` w `docs/index.html`** osobnym commitem.
   Każdy późniejszy push zmian w `worker/` na `main` deployuje ponownie.
4. **GitHub Pages**: Settings → Pages → Source: „Deploy from a branch” → gałąź `main`,
   katalog `/docs` → Save. Po chwili formularz jest pod
   `https://<login>.github.io/<repo>/`.
5. Sprawdź: Actions → „Smoke test API” → Run workflow. Wypisuje tylko PASS/FAIL.

`ALLOWED_ORIGIN` w `worker/wrangler.toml` musi odpowiadać originowi strony z formularzem
(domyślnie `https://bulileusz.github.io`). Kilka wartości oddziela się przecinkiem.

### Wariant B: lokalnie z wranglerem

```bash
cd worker
npm install
npx wrangler login                                  # interaktywne, otwiera przeglądarkę
npx wrangler d1 create contech-it-audit             # skopiuj database_id do wrangler.toml
npm run db:migrate                                  # schemat na produkcyjnej bazie
npx wrangler deploy                                 # wypisze adres https://...workers.dev
npx wrangler secret put ADMIN_KEY                   # wpisz długi losowy klucz
npx wrangler secret put HASH_SALT                   # np. wynik: openssl rand -hex 32
```

Adres wypisany przez `wrangler deploy` wpisz do `CONFIG.ENDPOINT` w `docs/index.html`
i wypchnij na `main`.

### Praca lokalna

```bash
cd worker
cp .dev.vars.example .dev.vars                      # wpisz własne wartości
npm run db:migrate:local
npm run dev                                         # API na http://localhost:8787
# w drugim terminalu: statyczny serwer z formularzem, np.
python3 -m http.server 8788 --directory ../docs     # origin http://localhost:8788 jest w .dev.vars.example
```

Do testów lokalnych ustaw tymczasowo `ENDPOINT: "http://localhost:8787"` w kopii
`index.html`; nie commituj tej zmiany.

## Eksport danych

Zmienne poniżej ustaw we własnej powłoce, klucz nigdy nie trafia do repo.

```bash
API=https://<adres-workera>.workers.dev
ADMIN_KEY=<twój klucz>

# CSV dla Excela PL: BOM UTF-8, separator średnik, CRLF, jedna kolumna na pytanie
curl -sS "$API/export?format=csv" -H "Authorization: Bearer $ADMIN_KEY" -o odpowiedzi.csv

# tylko zgłoszenia wysłane (bez szkiców)
curl -sS "$API/export?format=csv&status=final" -H "Authorization: Bearer $ADMIN_KEY" -o odpowiedzi.csv

# pełny JSON z payloadem
curl -sS "$API/export?format=json" -H "Authorization: Bearer $ADMIN_KEY" | jq .
```

W Excelu wystarczy podwójne kliknięcie na plik: BOM wymusza UTF-8, średnik jest domyślnym
separatorem w polskiej wersji. Komórki zaczynające się od `=`, `+`, `-`, `@` mają dopisany
apostrof, żeby Excel nie wykonał ich jako formuły. Odpowiedzi wielokrotnego wyboru są
złączone znakiem ` | `. Pliki `*.csv` są w `.gitignore`.

Kolumny CSV: `id, status, created_at, updated_at, company, filler, phone, date, answered,
answered_all, total_required, <1. treść pytania> … <43. treść pytania>, ua, ip_hash`.

## Testy

### API (curl)

Skrypt `worker/test/smoke.sh` przechodzi po kolei przez wszystkie przypadki i wypisuje
wyłącznie PASS/FAIL (nadaje się do CI publicznego repo):

```bash
API=https://<adres-workera>.workers.dev ORIGIN=https://bulileusz.github.io ADMIN_KEY=<klucz> \
  bash worker/test/smoke.sh
# dodatkowo rate limit (zużywa limit 60/10 min dla Twojego IP):
RATE_TEST=1 API=... ORIGIN=... ADMIN_KEY=... bash worker/test/smoke.sh
```

Ręcznie, pojedyncze komendy (`$API`, `$ORIGIN`, `$ADMIN_KEY` jak wyżej, `$ID` to dowolny UUID):

```bash
ID=$(uuidgen | tr 'A-Z' 'a-z')
BODY='{"id":"'$ID'","website":"","company":"Test","filler":"Jan","phone":"000","answered":1,
  "payload":{"meta":{"company":"Test","filler":"Jan","phone":"000","date":"2026-01-01"},
  "answers":[{"id":"q1","n":1,"sec":"A. Ludzie i skala","q":"Ile osób łącznie pracuje w firmie?","t":"radio","v":"4–9"}]}}'

# 1. /draft tworzy rekord (200, status draft); drugi POST z tym samym id aktualizuje
curl -i -X POST "$API/draft"  -H "Origin: $ORIGIN" -H "Content-Type: application/json" -d "$BODY"
curl -i -X POST "$API/draft"  -H "Origin: $ORIGIN" -H "Content-Type: application/json" -d "${BODY/Test/Test 2}"

# 2. /submit ustawia final; kolejny /draft go nie nadpisuje (odpowiedź zgłasza status final)
curl -i -X POST "$API/submit" -H "Origin: $ORIGIN" -H "Content-Type: application/json" -d "$BODY"
curl -i -X POST "$API/draft"  -H "Origin: $ORIGIN" -H "Content-Type: application/json" -d "$BODY"

# 3. obcy origin -> 403
curl -i -X POST "$API/draft" -H "Origin: https://obcy.example" -H "Content-Type: application/json" -d "$BODY"

# 4. preflight -> 204 z Access-Control-Allow-Origin/-Methods/-Headers/-Max-Age
curl -i -X OPTIONS "$API/draft" -H "Origin: $ORIGIN" \
  -H "Access-Control-Request-Method: POST" -H "Access-Control-Request-Headers: content-type"

# 5. /export bez tokenu -> 401; z tokenem -> CSV z BOM (pierwsze bajty EF BB BF)
curl -i "$API/export?format=csv"
curl -sS "$API/export?format=csv" -H "Authorization: Bearer $ADMIN_KEY" | head -c 3 | od -An -tx1

# 6. body 200 KB -> 413
{ printf '{"id":"%s","payload":{"x":"' "$ID"; head -c 200000 /dev/zero | tr '\0' a; printf '"}}'; } > big.json
curl -i -X POST "$API/draft" -H "Origin: $ORIGIN" -H "Content-Type: application/json" --data-binary @big.json

# 7. honeypot niepusty -> 200, ale rekordu nie ma w eksporcie
curl -i -X POST "$API/draft" -H "Origin: $ORIGIN" -H "Content-Type: application/json" \
  -d "${BODY/\"website\":\"\"/\"website\":\"http://spam\"}"
```

Rekordy testowe mają firmę `SMOKE-TEST ...`. Workflow „Smoke test API” usuwa je sam na
końcu przebiegu. Po testach uruchamianych ręcznie usuwa je workflow „Czyszczenie bazy”
(Actions → Run workflow → tryb `smoke`) albo lokalnie:

```bash
CLOUDFLARE_API_TOKEN=<token> MODE=smoke bash worker/test/db-cleanup.sh
```

### Przeglądarka (lista kontrolna)

Sprawdzone w Chromium (Playwright, 55 asercji) i do powtórzenia ręcznie po wdrożeniu:

- wypełnij część pytań, zamknij kartę, wróć: pasek „Przywrócono odpowiedzi…”, te same
  odpowiedzi, ten sam identyfikator, ostatnia zmiana dostarczona beaconem,
- DevTools → Network → Offline → „Wyślij odpowiedzi”: komunikat z drogą awaryjną, przycisk
  znów aktywny, localStorage nietknięty, „Pobierz jako plik” działa; po włączeniu sieci
  wysyłka przechodzi, formularz blokuje się i pokazuje numer zgłoszenia,
- nawigacja klawiaturą: Tab przechodzi przez wszystkie 43 pytania i dociera do „Wyślij”,
  strzałki wybierają odpowiedź, spacja zaznacza checkbox, honeypot nie dostaje fokusu,
- szerokość 375 px: brak przewijania poziomego, pasek postępu mieści status zapisu,
- druk / PDF: widoczne tylko wybrane odpowiedzi i numer zgłoszenia.

## Bezpieczeństwo i dane

- Sekrety (`ADMIN_KEY`, `HASH_SALT`, token Cloudflare) istnieją tylko jako sekrety wranglera
  i sekrety GitHub Actions. W repo nie ma ich nigdzie; `.dev.vars` jest ignorowany.
- Worker nie loguje payloadu ani adresów IP. `wrangler tail` pokazuje metadane żądań na żywo,
  ale nic nie zapisuje.
- Klauzula informacyjna dla wypełniającego jest przy przycisku wysyłki w formularzu.
- Usunięcie zgłoszenia na prośbę klienta: Actions → „Czyszczenie bazy” → tryb `id` →
  wpisz UUID zgłoszenia (numer zgłoszenia z formularza to jego pierwsze 8 znaków, pełny UUID
  jest w eksporcie). Lokalnie: `CLOUDFLARE_API_TOKEN=<token> MODE=id TARGET_ID=<uuid> bash worker/test/db-cleanup.sh`.
