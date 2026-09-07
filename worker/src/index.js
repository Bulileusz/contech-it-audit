/**
 * Karta rozeznania IT: backend na Cloudflare Workers + D1.
 *
 * Endpointy:
 *   OPTIONS *        preflight CORS (tylko dla ALLOWED_ORIGIN)
 *   GET     /        prosty health-check
 *   POST    /draft   upsert po id, status 'draft'; nie nadpisuje rekordu 'final'
 *   POST    /submit  upsert po id, status 'final'
 *   GET     /export  Authorization: Bearer <ADMIN_KEY>; ?format=csv|json[&status=draft|final]
 *
 * Zasady:
 *   - żadnego logowania payloadu ani adresu IP (tylko komunikaty błędów),
 *   - IP trafia do bazy wyłącznie jako SHA-256(IP + HASH_SALT),
 *   - body > 128 KB odrzucane (413), honeypot 'website' = 200 bez zapisu,
 *   - rate limit 60 żądań / 10 min na ip_hash (licznik w D1).
 */

const MAX_BODY_BYTES = 128 * 1024;
const RATE_LIMIT_MAX = 60;
const RATE_WINDOW_SECONDS = 600;
const MAX_SHORT_TEXT = 200;
const MAX_UA = 300;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

const CSV_SEPARATOR = ";";
const CSV_BOM = "\uFEFF";

export default {
  async fetch(request, env, ctx) {
    try {
      return await handle(request, env, ctx);
    } catch (err) {
      // Celowo tylko komunikat błędu. Nigdy body, nigdy IP.
      console.warn("unhandled error:", err && err.message ? err.message : String(err));
      return json({ ok: false, error: "internal" }, 500, corsFor(request, env));
    }
  },
};

/* ------------------------------------------------------------------ */
/* routing                                                             */
/* ------------------------------------------------------------------ */

async function handle(request, env, ctx) {
  const url = new URL(request.url);
  const origin = request.headers.get("Origin");
  const originOk = origin !== null && isAllowedOrigin(origin, env);

  if (request.method === "OPTIONS") {
    if (!originOk) return text("Forbidden", 403);
    return new Response(null, { status: 204, headers: corsHeaders(origin) });
  }

  // Żądanie z przeglądarki z obcego origin: 403. Brak nagłówka Origin
  // (curl, narzędzia administratora) przechodzi dalej bez nagłówków CORS.
  if (origin !== null && !originOk) {
    return json({ ok: false, error: "forbidden_origin" }, 403);
  }
  const cors = originOk ? corsHeaders(origin) : {};

  if (url.pathname === "/" || url.pathname === "") {
    if (request.method !== "GET") return json({ ok: false, error: "method_not_allowed" }, 405, cors);
    return json({ ok: true, service: "contech-it-audit-api" }, 200, cors);
  }

  const ipHash = await hashIp(request, env);
  const limited = await rateLimit(env, ctx, ipHash);
  if (limited) {
    return json({ ok: false, error: "rate_limited" }, 429, {
      ...cors,
      "Retry-After": String(RATE_WINDOW_SECONDS),
    });
  }

  if (url.pathname === "/draft" || url.pathname === "/submit") {
    if (request.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405, cors);
    return handleUpsert(request, env, cors, ipHash, url.pathname === "/submit" ? "final" : "draft");
  }

  if (url.pathname === "/export") {
    if (request.method !== "GET") return json({ ok: false, error: "method_not_allowed" }, 405, cors);
    return handleExport(request, env, url, cors);
  }

  return json({ ok: false, error: "not_found" }, 404, cors);
}

/* ------------------------------------------------------------------ */
/* POST /draft, POST /submit                                           */
/* ------------------------------------------------------------------ */

async function handleUpsert(request, env, cors, ipHash, status) {
  const body = await readBodyLimited(request, MAX_BODY_BYTES);
  if (body.tooLarge) return json({ ok: false, error: "payload_too_large" }, 413, cors);

  let data;
  try {
    data = JSON.parse(body.text);
  } catch (_) {
    return json({ ok: false, error: "bad_json" }, 400, cors);
  }
  if (!isPlainObject(data)) return json({ ok: false, error: "bad_json" }, 400, cors);

  // Honeypot: bot wypełnił ukryte pole. Odpowiadamy sukcesem, nic nie zapisujemy.
  if (data.website !== undefined && data.website !== null && String(data.website).trim() !== "") {
    return json({ ok: true }, 200, cors);
  }

  const id = typeof data.id === "string" ? data.id.trim().toLowerCase() : "";
  if (!UUID_RE.test(id)) return json({ ok: false, error: "bad_id" }, 400, cors);

  const payload = isPlainObject(data.payload) ? data.payload : null;
  if (!payload) return json({ ok: false, error: "bad_payload" }, 400, cors);
  const meta = isPlainObject(payload.meta) ? payload.meta : {};

  const company = shortText(data.company, meta.company);
  const filler = shortText(data.filler, meta.filler);
  const phone = shortText(data.phone, meta.phone);
  const answered = Number.isInteger(data.answered) && data.answered >= 0 && data.answered <= 10000
    ? data.answered
    : 0;
  const ua = (request.headers.get("User-Agent") || "").slice(0, MAX_UA);
  const now = new Date().toISOString();
  const payloadText = JSON.stringify(payload);

  const insert = `
    INSERT INTO submissions
      (id, created_at, updated_at, status, company, filler, phone, payload, answered, ua, ip_hash)
    VALUES (?1, ?2, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
    ON CONFLICT(id) DO UPDATE SET
      updated_at = excluded.updated_at,
      status     = excluded.status,
      company    = excluded.company,
      filler     = excluded.filler,
      phone      = excluded.phone,
      payload    = excluded.payload,
      answered   = excluded.answered,
      ua         = excluded.ua,
      ip_hash    = excluded.ip_hash
    ${status === "draft" ? "WHERE submissions.status <> 'final'" : ""}`;

  const results = await env.DB.batch([
    env.DB.prepare(insert).bind(id, now, status, company, filler, phone, payloadText, answered, ua, ipHash),
    env.DB.prepare("SELECT status, updated_at FROM submissions WHERE id = ?1").bind(id),
  ]);

  const row = results[1] && results[1].results && results[1].results[0];
  const stored = row ? row.status : status;

  return json({ ok: true, id, status: stored, updated_at: row ? row.updated_at : now }, 200, cors);
}

/* ------------------------------------------------------------------ */
/* GET /export                                                         */
/* ------------------------------------------------------------------ */

async function handleExport(request, env, url, cors) {
  if (!env.ADMIN_KEY) {
    return json({ ok: false, error: "admin_key_not_configured" }, 503, cors);
  }
  const auth = request.headers.get("Authorization") || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token || !safeEqual(token, env.ADMIN_KEY)) {
    return json({ ok: false, error: "unauthorized" }, 401, { ...cors, "WWW-Authenticate": "Bearer" });
  }

  const format = url.searchParams.get("format") === "csv" ? "csv" : "json";
  const statusFilter = url.searchParams.get("status");
  const where = statusFilter === "draft" || statusFilter === "final" ? "WHERE status = ?1" : "";
  const stmt = env.DB.prepare(
    `SELECT id, created_at, updated_at, status, company, filler, phone, payload, answered, ua, ip_hash
       FROM submissions ${where} ORDER BY updated_at DESC`,
  );
  const { results } = await (where ? stmt.bind(statusFilter) : stmt).all();
  const rows = results.map((r) => ({ ...r, payload: parseJsonSafe(r.payload) }));

  if (format === "csv") {
    const csv = CSV_BOM + toCsv(rows);
    return new Response(csv, {
      status: 200,
      headers: {
        ...cors,
        "Content-Type": "text/csv; charset=utf-8",
        "Content-Disposition": `attachment; filename="rozeznanie_it_${new Date().toISOString().slice(0, 10)}.csv"`,
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      },
    });
  }
  return json({ ok: true, count: rows.length, rows }, 200, cors);
}

/**
 * CSV dla Excela w polskiej wersji: BOM UTF-8, separator ';', CRLF.
 * Kolumny pytań budowane są z payload.answers wszystkich rekordów
 * (unia po id pytania, posortowana po numerze), nagłówek = numer i treść pytania.
 */
function toCsv(rows) {
  const questions = new Map();
  for (const r of rows) {
    const answers = r.payload && Array.isArray(r.payload.answers) ? r.payload.answers : [];
    for (const a of answers) {
      if (!a || typeof a.id !== "string") continue;
      if (!questions.has(a.id)) {
        questions.set(a.id, { n: Number(a.n) || 0, label: `${a.n || ""}. ${a.q || a.id}`.trim() });
      }
    }
  }
  const qCols = [...questions.entries()].sort((x, y) => x[1].n - y[1].n);

  const header = [
    "id", "status", "created_at", "updated_at", "company", "filler", "phone", "date",
    "answered", "answered_all", "total_required",
    ...qCols.map(([, q]) => q.label),
    "ua", "ip_hash",
  ];

  const lines = [header.map(csvCell).join(CSV_SEPARATOR)];
  for (const r of rows) {
    const p = r.payload || {};
    const meta = isPlainObject(p.meta) ? p.meta : {};
    const byId = new Map();
    if (Array.isArray(p.answers)) for (const a of p.answers) if (a && a.id) byId.set(a.id, a.v);
    const cells = [
      r.id, r.status, r.created_at, r.updated_at, r.company, r.filler, r.phone, meta.date,
      r.answered, p.answered_all, p.total_required,
      ...qCols.map(([id]) => formatAnswer(byId.get(id))),
      r.ua, r.ip_hash,
    ];
    lines.push(cells.map(csvCell).join(CSV_SEPARATOR));
  }
  return lines.join("\r\n") + "\r\n";
}

function formatAnswer(v) {
  if (Array.isArray(v)) return v.join(" | ");
  if (v === null || v === undefined) return "";
  return String(v);
}

function csvCell(v) {
  let s = v === null || v === undefined ? "" : String(v);
  // Ochrona przed formułami w Excelu: komórka zaczynająca się od = + - @ dostaje apostrof.
  if (/^[=+\-@\t\r]/.test(s)) s = "'" + s;
  if (/[";\r\n]/.test(s)) s = '"' + s.replace(/"/g, '""') + '"';
  return s;
}

/* ------------------------------------------------------------------ */
/* rate limit (D1)                                                     */
/* ------------------------------------------------------------------ */

async function rateLimit(env, ctx, ipHash) {
  const window = Math.floor(Date.now() / 1000 / RATE_WINDOW_SECONDS);
  const res = await env.DB.prepare(
    `INSERT INTO rate_limits (ip_hash, window_start, count) VALUES (?1, ?2, 1)
     ON CONFLICT(ip_hash, window_start) DO UPDATE SET count = count + 1
     RETURNING count`,
  ).bind(ipHash, window).first();
  const count = res ? Number(res.count) : 1;

  // Sprzątanie starych okien, rzadko i poza ścieżką odpowiedzi.
  if (Math.random() < 0.05) {
    ctx.waitUntil(
      env.DB.prepare("DELETE FROM rate_limits WHERE window_start < ?1").bind(window - 1).run().catch(() => {}),
    );
  }
  return count > RATE_LIMIT_MAX;
}

/* ------------------------------------------------------------------ */
/* pomocnicze                                                          */
/* ------------------------------------------------------------------ */

function allowedOrigins(env) {
  return String(env.ALLOWED_ORIGIN || "")
    .split(",")
    .map((s) => s.trim().replace(/\/+$/, "").toLowerCase())
    .filter(Boolean);
}

function isAllowedOrigin(origin, env) {
  const o = String(origin).trim().replace(/\/+$/, "").toLowerCase();
  return o !== "" && o !== "null" && allowedOrigins(env).includes(o);
}

function corsHeaders(origin) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function corsFor(request, env) {
  const origin = request.headers.get("Origin");
  return origin !== null && isAllowedOrigin(origin, env) ? corsHeaders(origin) : {};
}

function json(obj, status, extra) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...(extra || {}),
    },
  });
}

function text(s, status, extra) {
  return new Response(s, {
    status,
    headers: { "Content-Type": "text/plain; charset=utf-8", "Cache-Control": "no-store", ...(extra || {}) },
  });
}

function isPlainObject(v) {
  return v !== null && typeof v === "object" && !Array.isArray(v);
}

function shortText(primary, fallback) {
  const v = typeof primary === "string" && primary.trim() !== "" ? primary : fallback;
  return typeof v === "string" ? v.trim().slice(0, MAX_SHORT_TEXT) : "";
}

function parseJsonSafe(s) {
  try {
    return JSON.parse(s);
  } catch (_) {
    return null;
  }
}

/**
 * Czyta body strumieniowo. Przy Content-Length ponad limit odrzuca od razu.
 * Bez Content-Length (chunked) czyta do limitu; nadmiar drenuje bez buforowania
 * (przerwanie strumienia w trakcie odbioru bywa źle znoszone przez proxy),
 * a dopiero przy HARD_CAP anuluje połączenie.
 */
async function readBodyLimited(request, max) {
  const declared = request.headers.get("Content-Length");
  if (declared !== null && Number(declared) > max) return { tooLarge: true };
  if (!request.body) return { text: "" };

  const HARD_CAP = 4 * 1024 * 1024;
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  let tooLarge = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      tooLarge = true;
      chunks.length = 0;
      if (size > HARD_CAP) {
        await reader.cancel().catch(() => {});
        break;
      }
      continue;
    }
    chunks.push(value);
  }
  if (tooLarge) return { tooLarge: true };
  const buf = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    buf.set(c, offset);
    offset += c.byteLength;
  }
  return { text: new TextDecoder("utf-8").decode(buf) };
}

async function hashIp(request, env) {
  const ip = request.headers.get("CF-Connecting-IP") || "";
  if (!env.HASH_SALT) console.warn("HASH_SALT is not set; using unsalted hash");
  return sha256Hex(`${ip}|${env.HASH_SALT || ""}`);
}

async function sha256Hex(s) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** Porównanie w stałym czasie (różna długość ujawnia tylko długość). */
function safeEqual(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(String(a));
  const bb = enc.encode(String(b));
  if (ab.byteLength !== bb.byteLength) return false;
  if (typeof crypto.subtle.timingSafeEqual === "function") return crypto.subtle.timingSafeEqual(ab, bb);
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}
