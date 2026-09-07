-- Schemat bazy D1 dla karty rozeznania IT.
-- Uruchomienie: wrangler d1 execute contech-it-audit --remote --file=./schema.sql -y
-- Idempotentny (CREATE ... IF NOT EXISTS), można odpalać wielokrotnie.

CREATE TABLE IF NOT EXISTS submissions (
  id          TEXT PRIMARY KEY,                 -- UUID generowany po stronie klienta
  created_at  TEXT NOT NULL,                    -- ISO 8601 (UTC)
  updated_at  TEXT NOT NULL,                    -- ISO 8601 (UTC)
  status      TEXT NOT NULL CHECK (status IN ('draft', 'final')),
  company     TEXT,
  filler      TEXT,
  phone       TEXT,
  payload     TEXT NOT NULL,                    -- pełny JSON odpowiedzi
  answered    INTEGER NOT NULL DEFAULT 0,       -- liczba uzupełnionych pytań obowiązkowych
  ua          TEXT,
  ip_hash     TEXT                              -- SHA-256(IP + sól), nigdy surowe IP
);

CREATE INDEX IF NOT EXISTS idx_submissions_status_updated
  ON submissions (status, updated_at DESC);

-- Licznik do rate limitu: okno 10 minut per ip_hash.
CREATE TABLE IF NOT EXISTS rate_limits (
  ip_hash       TEXT    NOT NULL,
  window_start  INTEGER NOT NULL,               -- floor(unix_time / 600)
  count         INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (ip_hash, window_start)
);
