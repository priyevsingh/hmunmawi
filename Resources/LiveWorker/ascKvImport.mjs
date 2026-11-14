// One-time KV wh: backlog → DO queue (mockable; no live account calls from tests).

export const DEFAULT_IMPORT_BUDGET = 100;
export const MAX_IMPORT_BUDGET = 500;

export function parseWhKey(key) {
  const m = /^wh:(\d{13}):(.+)$/.exec(String(key || ""));
  if (!m) return null;
  return { at: Number(m[1]), eventId: m[2] };
}

export function kvItemToIngest(key, rawJson) {
  let item;
  try {
    item = typeof rawJson === "string" ? JSON.parse(rawJson) : rawJson;
  } catch {
    return { ok: false, error: "bad json" };
  }
  const parsed = parseWhKey(key);
  const eventId = item?.id || parsed?.eventId;
  if (!eventId) return { ok: false, error: "no id" };
  const at = Number(item?.at) || parsed?.at || Date.now();
  return { ok: true, eventId, at, item: { ...item, id: eventId, at } };
}

/// Paginated import from an OUTBOX-like KV binding (used only when ASC_KV_IMPORT=1).
export async function importKvPage({ outbox, stub, cursor, budget = DEFAULT_IMPORT_BUDGET, store }) {
  const cap = Math.min(Math.max(1, budget), MAX_IMPORT_BUDGET);
  const page = await outbox.list({ prefix: "wh:", cursor, limit: cap });
  const keys = [...page.keys].sort((a, b) => String(a.name).localeCompare(String(b.name)));
  let imported = 0;
  let skipped = 0;
  let duplicates = 0;
  const errors = [];
  for (const k of keys) {
    const raw = await outbox.get(k.name);
    if (!raw) {
      skipped++;
      continue;
    }
    const norm = kvItemToIngest(k.name, raw);
    if (!norm.ok) {
      errors.push({ key: k.name, error: norm.error });
      skipped++;
      continue;
    }
    const r = await stub.ingest({ eventId: norm.eventId, at: norm.at, item: norm.item });
    if (!r?.ok) {
      errors.push({ key: k.name, error: "ingest failed" });
      skipped++;
      continue;
    }
    if (r.duplicate) duplicates++;
    else imported++;
  }
  const nextCursor = page.list_complete ? null : page.cursor;
  const checkpoint = {
    kv_cursor: nextCursor,
    list_complete: page.list_complete,
    imported,
    skipped,
    duplicates,
    examined: page.keys.length,
    updated_ms: Date.now(),
  };
  if (store) await store(checkpoint);
  return checkpoint;
}
