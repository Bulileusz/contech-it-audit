# contech-it-audit

## Przegląd
Karta rozeznania IT dla małej firmy budowlanej: jednoplikowy formularz HTML (43 pytania
w 7 sekcjach) na GitHub Pages (`docs/index.html`) + backend Cloudflare Workers + D1
(`worker/`), który zbiera odpowiedzi (szkice i wysyłki końcowe) do bazy.
Szczegóły działania, wdrożenia i eksportu danych: zobacz `README.md`.

## Komendy
- Setup workera: `cd worker && npm install`
- Praca lokalna: `cp worker/.dev.vars.example worker/.dev.vars`, `npm run db:migrate:local`, `npm run dev` (API na `:8787`)
- Statyczny serwer formularza (lokalnie): `python3 -m http.server 8788 --directory docs`
- Deploy workera: `npx wrangler deploy` (lub przez GitHub Actions `deploy-worker.yml`)
- Migracja bazy (produkcja): `npm run db:migrate`
- Testy dymne API: `bash worker/test/smoke.sh` (wymaga `API`, `ORIGIN`, `ADMIN_KEY` w env)

## Styl kodu
- Klient: czysty HTML/CSS/JS w jednym pliku (`docs/index.html`), zero zależności,
  zero bundlera, brak fontów z CDN — nie proponuj wprowadzania frameworków ani buildów.
- Ustawienia klienta scentralizowane w bloku `CONFIG` na początku `<script>`.
- Worker: zwykły JS (Cloudflare Workers runtime), bez frameworka.

## Commity i PR
- Conventional Commits, podpisywane (SSH). Nie commituj bezpośrednio do `main`.

## Bezpieczeństwo
- Sekrety (`ADMIN_KEY`, `HASH_SALT`, token Cloudflare) tylko jako sekrety wranglera /
  GitHub Actions — nigdy w repo. `.dev.vars` jest gitignorowany.
- Worker nie loguje payloadu ani adresów IP; IP trafia do bazy wyłącznie jako SHA-256 z solą.
- Eksporty danych (`*.csv`) nigdy nie trafiają do repo.
