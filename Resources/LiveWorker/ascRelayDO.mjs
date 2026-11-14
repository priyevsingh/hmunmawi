// Per-relay ASC webhook queue: SQLite-backed ordered log + hibernatable WebSocket push.
// One Durable Object instance per relay namespace (getByName("asc")).
import { DurableObject } from "cloudflare:workers";

const RETENTION_MS = 7 * 24 * 3600 * 1000;
const MAX_PAGE = 500;

export class AscRelayDO extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env);
    ctx.blockConcurrencyWhile(async () => {
      ctx.storage.sql.exec(`
        CREATE TABLE IF NOT EXISTS events (
          seq INTEGER PRIMARY KEY AUTOINCREMENT,
          event_id TEXT NOT NULL UNIQUE,
          at INTEGER NOT NULL,
          payload TEXT NOT NULL,
          created_ms INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_events_at ON events(at);
        CREATE TABLE IF NOT EXISTS deliveries (
          consumer_id TEXT NOT NULL PRIMARY KEY,
          last_ack_seq INTEGER NOT NULL DEFAULT 0,
          last_delivered_seq INTEGER NOT NULL DEFAULT 0,
          last_ack_ms INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS import_state (
          source TEXT NOT NULL PRIMARY KEY,
          kv_cursor TEXT,
          imported_total INTEGER NOT NULL DEFAULT 0,
          updated_ms INTEGER NOT NULL DEFAULT 0
        );
      `);
      try {
        ctx.storage.sql.exec("ALTER TABLE deliveries ADD COLUMN last_delivered_seq INTEGER NOT NULL DEFAULT 0");
      } catch {
        /* column exists */
      }
    });
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
    for (const ws of ctx.getWebSockets()) {
      const att = ws.deserializeAttachment();
      if (att?.consumer_id) this.#deliverPending(ws, att.consumer_id);
    }
  }

  async ingest({ eventId, at, item }) {
    const created = Date.now();
    const payload = JSON.stringify(item);
    const existing = this.ctx.storage.sql
      .exec("SELECT seq FROM events WHERE event_id = ?", eventId)
      .toArray();
    let seq;
    if (existing.length) {
      seq = existing[0].seq;
    } else {
      const row = this.ctx.storage.sql
        .exec(
          "INSERT INTO events (event_id, at, payload, created_ms) VALUES (?, ?, ?, ?) RETURNING seq",
          eventId,
          at,
          payload,
          created,
        )
        .one();
      seq = row.seq;
      this.#broadcast({ type: "event", seq, event_id: eventId, at, item });
    }
    return { ok: true, seq, duplicate: existing.length > 0 };
  }

  async page({ afterSeq = 0, limit = 200 }) {
    const cap = Math.min(Math.max(1, limit), MAX_PAGE);
    const rows = this.ctx.storage.sql
      .exec(
        "SELECT seq, event_id, at, payload FROM events WHERE seq > ? ORDER BY seq ASC LIMIT ?",
        afterSeq,
        cap,
      )
      .toArray();
    const items = rows.map((r) => ({
      seq: r.seq,
      event_id: r.event_id,
      at: r.at,
      ...JSON.parse(r.payload),
    }));
    const next = items.length ? items[items.length - 1].seq : afterSeq;
    const more =
      this.ctx.storage.sql
        .exec("SELECT 1 FROM events WHERE seq > ? LIMIT 1", next)
        .toArray().length > 0;
    return { items, next_seq: next, has_more: more };
  }

  async importCheckpoint(source = "kv") {
    const row = this.ctx.storage.sql.exec("SELECT * FROM import_state WHERE source = ?", source).toArray();
    return row[0] || { source, kv_cursor: null, imported_total: 0, updated_ms: 0 };
  }

  async saveImportCheckpoint({ source = "kv", kv_cursor, imported_total }) {
    this.ctx.storage.sql.exec(
      `INSERT INTO import_state (source, kv_cursor, imported_total, updated_ms) VALUES (?, ?, ?, ?)
       ON CONFLICT(source) DO UPDATE SET kv_cursor = excluded.kv_cursor, imported_total = excluded.imported_total, updated_ms = excluded.updated_ms`,
      source,
      kv_cursor ?? null,
      imported_total ?? 0,
      Date.now(),
    );
    return { ok: true };
  }

  async ack({ consumerId, seq }) {
    if (!consumerId || !Number.isFinite(seq) || seq < 0) return { ok: false, error: "bad ack" };
    const max = this.ctx.storage.sql.exec("SELECT COALESCE(MAX(seq), 0) AS m FROM events").one().m;
    if (seq > max) return { ok: false, error: "seq too high" };
    const prev = this.ctx.storage.sql
      .exec("SELECT last_ack_seq, last_delivered_seq FROM deliveries WHERE consumer_id = ?", consumerId)
      .toArray();
    const last = prev.length ? prev[0].last_ack_seq : 0;
    const delivered = prev.length ? prev[0].last_delivered_seq : 0;
    if (seq > delivered) return { ok: false, error: "not delivered yet" };
    if (seq < last) return { ok: true, seq: last, regressed: true };
    this.ctx.storage.sql.exec(
      "INSERT INTO deliveries (consumer_id, last_ack_seq, last_ack_ms) VALUES (?, ?, ?) ON CONFLICT(consumer_id) DO UPDATE SET last_ack_seq = excluded.last_ack_seq, last_ack_ms = excluded.last_ack_ms",
      consumerId,
      seq,
      Date.now(),
    );
    this.#maybeCleanup();
    return { ok: true, seq };
  }

  async fetch(request) {
    const url = new URL(request.url);
    if (request.headers.get("Upgrade") === "websocket") {
      return this.#acceptSocket(request, url);
    }
    if (url.pathname === "/rpc/ingest" && request.method === "POST") {
      return json(await this.ingest(await request.json()));
    }
    if (url.pathname === "/rpc/page" && request.method === "GET") {
      const afterSeq = Number(url.searchParams.get("after_seq")) || 0;
      const limit = Number(url.searchParams.get("limit")) || 200;
      return json(await this.page({ afterSeq, limit }));
    }
    if (url.pathname === "/rpc/ack" && request.method === "POST") {
      return json(await this.ack(await request.json()));
    }
    return json({ error: "not found" }, 404);
  }

  async webSocketMessage(ws, message) {
    const att = ws.deserializeAttachment();
    if (!att?.consumer_id) {
      ws.close(1008, "no consumer");
      return;
    }
    let body;
    try {
      body = JSON.parse(typeof message === "string" ? message : new TextDecoder().decode(message));
    } catch {
      ws.send(JSON.stringify({ type: "error", error: "bad json" }));
      return;
    }
    if (body.type === "ack" && Number.isFinite(body.seq)) {
      const r = await this.ack({ consumerId: att.consumer_id, seq: body.seq });
      ws.send(JSON.stringify({ type: "ack_ok", ...r }));
      return;
    }
    if (body.type === "catchup") {
      const after = Number.isFinite(body.after_seq) ? body.after_seq : att.last_sent_seq || 0;
      await this.#deliverPending(ws, att.consumer_id, after);
      return;
    }
    ws.send(JSON.stringify({ type: "error", error: "unknown command" }));
  }

  async webSocketClose(ws, code, reason) {
    ws.close(code, reason);
  }

  #acceptSocket(request, url) {
    const consumerId = url.searchParams.get("consumer")?.slice(0, 64) || "mac-default";
    const afterSeq = Number(url.searchParams.get("after_seq")) || 0;
    for (const existing of this.ctx.getWebSockets()) {
      const att = existing.deserializeAttachment();
      if (att?.consumer_id === consumerId) {
        existing.close(1000, "replaced");
      }
    }
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment({ consumer_id: consumerId, last_sent_seq: afterSeq });
    this.ctx.waitUntil(this.#deliverPending(server, consumerId, afterSeq));
    return new Response(null, { status: 101, webSocket: client });
  }

  async #deliverPending(ws, consumerId, afterSeq = 0) {
    const saved = ws.deserializeAttachment() || { consumer_id: consumerId };
    let cursor = Number.isFinite(afterSeq) ? afterSeq : saved.last_sent_seq || 0;
    const ackRow = this.ctx.storage.sql
      .exec("SELECT last_ack_seq FROM deliveries WHERE consumer_id = ?", consumerId)
      .toArray();
    if (ackRow.length && ackRow[0].last_ack_seq > cursor) cursor = ackRow[0].last_ack_seq;
    let hasMore = true;
    while (hasMore && ws.readyState === WebSocket.OPEN) {
      const page = await this.page({ afterSeq: cursor, limit: 200 });
      for (const item of page.items) {
        ws.send(JSON.stringify({ type: "event", seq: item.seq, event_id: item.event_id, at: item.at, item }));
        cursor = item.seq;
        ws.serializeAttachment({ consumer_id: consumerId, last_sent_seq: cursor });
        this.#recordDelivered(consumerId, cursor);
      }
      hasMore = page.has_more;
      if (!page.items.length) break;
    }
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: "caught_up", next_seq: cursor }));
    }
  }

  #broadcast(msg) {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws.readyState !== WebSocket.OPEN) continue;
      ws.send(JSON.stringify(msg));
      const att = ws.deserializeAttachment();
      if (att?.consumer_id && Number.isFinite(msg?.seq)) this.#recordDelivered(att.consumer_id, msg.seq);
    }
  }

  #recordDelivered(consumerId, seq) {
    this.ctx.storage.sql.exec(
      `INSERT INTO deliveries (consumer_id, last_ack_seq, last_delivered_seq, last_ack_ms) VALUES (?, 0, ?, 0)
       ON CONFLICT(consumer_id) DO UPDATE SET last_delivered_seq = CASE
         WHEN excluded.last_delivered_seq > deliveries.last_delivered_seq THEN excluded.last_delivered_seq
         ELSE deliveries.last_delivered_seq END`,
      consumerId,
      seq,
    );
  }

  #maybeCleanup() {
    const cutoff = Date.now() - RETENTION_MS;
    const ackFloor = this.ctx.storage.sql
      .exec("SELECT COALESCE(MIN(last_ack_seq), 0) AS m FROM deliveries")
      .one().m;
    const consumerCount = this.ctx.storage.sql.exec("SELECT COUNT(*) AS c FROM deliveries").one().c;
    if (consumerCount === 0) return;
    this.ctx.storage.sql.exec("DELETE FROM events WHERE created_ms < ? AND seq <= ?", cutoff, ackFloor);
  }
}

const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
