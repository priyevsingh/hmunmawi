// Worker HTTP handlers (no cloudflare:workers import — safe for plain Node legacy tests).
import { verifyJws, VerifyError } from "./verify.mjs";
import { importKvPage, DEFAULT_IMPORT_BUDGET } from "./ascKvImport.mjs";

const TTL = 7 * 24 * 3600;
// The worker's code version, shown at /asc/capabilities. Bump it whenever any file in this folder changes (and update
// Resources/LiveWorkerVersion.json and LivePurchases.workerCodeVersion; a test checks all three against the files), so
// Hmunmawi knows a deployed worker is older and updates it.
export const WORKER_CODE_VERSION = 2;
const json = (body, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });

function sameSecret(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

function authed(request, env) {
  const auth = request.headers.get("authorization") || "";
  return env.RELAY_KEY && sameSecret(auth, `Bearer ${env.RELAY_KEY}`);
}

function ascRelayStub(env) {
  if (!env.ASC_RELAY) return null;
  return env.ASC_RELAY.getByName("asc");
}

function queueV2(env) {
  return (env.ASC_QUEUE_V2 === "1" || env.ASC_QUEUE_V2 === "true") && !!env.ASC_RELAY;
}

function mirrorKv(env) {
  return env.ASC_KV_MIRROR === "1" || env.ASC_KV_MIRROR === "true";
}

async function receive(request, env) {
  // Only your own apps' notifications: without a list of bundle ids nothing is taken (Hmunmawi sets it on deploy).
  const allowed = (env.BUNDLE_IDS || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!allowed.length) return json({ error: "no app list: add your app names in Hmunmawi and deploy again" }, 503);
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.length > 64 * 1024) return json({ error: "too large" }, 413);
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "not JSON" }, 400);
  }
  try {
    const n = await verifyJws(body?.signedPayload);
    const data = n.data || {};
    if (!allowed.includes(data.bundleId)) return json({ error: "unknown app" }, 403);
    const tx = data.signedTransactionInfo ? await verifyJws(data.signedTransactionInfo) : {};
    if (tx.bundleId && !allowed.includes(tx.bundleId)) return json({ error: "unknown app" }, 403);
    const rn = data.signedRenewalInfo ? await verifyJws(data.signedRenewalInfo) : {};
    const at = Number(n.signedDate) || Date.now();
    const item = {
      at,
      type: n.notificationType,
      subtype: n.subtype || null,
      bundleId: data.bundleId || null,
      environment: data.environment || null,
      product: tx.productId || null,
      price: typeof tx.price === "number" ? tx.price / 1000 : null,
      currency: tx.currency || null,
      storefront: tx.storefront || null,
      offer: tx.offerType ?? null,
      purchased: tx.purchaseDate || null,
      expires: tx.expiresDate || null,
      autoRenew: rn.autoRenewStatus ?? null,
      inFamily: tx.inAppOwnershipType === "FAMILY_SHARED",
    };
    const key = `ob:${String(at).padStart(13, "0")}:${n.notificationUUID || crypto.randomUUID()}`;
    await env.OUTBOX.put(key, JSON.stringify(item), { expirationTtl: TTL });
    return json({ ok: true });
  } catch (e) {
    const status = e instanceof VerifyError ? e.status || 401 : 400;
    return json({ error: e instanceof VerifyError ? e.message : "could not read the notification" }, status);
  }
}

async function outbox(request, env, url) {
  if (!authed(request, env)) return json({ error: "unauthorized" }, 401);
  const since = Number(url.searchParams.get("since")) || 0;
  const keyTime = (k) => Number(String(k).slice(3, 16)) || 0;
  const items = [];
  let cursor;
  do {
    const page = await env.OUTBOX.list({ prefix: "ob:", cursor, limit: 500 });
    for (const k of page.keys) {
      if (keyTime(k.name) <= since) continue;
      const v = await env.OUTBOX.get(k.name);
      if (v) items.push({ key: k.name, ...JSON.parse(v) });
      if (items.length >= 200) break;
    }
    cursor = page.list_complete || items.length >= 200 ? undefined : page.cursor;
  } while (cursor);
  return json({ items });
}

export async function validSignature(secret, raw, header) {
  const m = /^hmacsha256=([0-9a-fA-F]{64})$/.exec(String(header || "").trim());
  if (!secret || !m) return false;
  const unhex = (h) => new Uint8Array((h.match(/../g) || []).map((x) => parseInt(x, 16)));
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  return crypto.subtle.verify("HMAC", key, unhex(m[1].toLowerCase()), raw);
}

function ascItem(body) {
  const d = body?.data || {}, a = d.attributes || {}, inst = d.relationships?.instance?.data || {};
  const str = (v) => (typeof v === "string" ? v.slice(0, 120) : null);
  const at = Date.parse(a.timestamp) || Date.now();
  const eventId = str(d.id) || crypto.randomUUID();
  const item = {
    at,
    type: str(d.type),
    id: eventId,
    from: str(a.oldValue ?? a.oldExternalBuildState ?? a.oldState),
    to: str(a.newValue ?? a.newExternalBuildState ?? a.newState),
    instanceType: str(inst.type),
    instanceId: str(inst.id),
  };
  return { item, eventId, at };
}

async function receiveAsc(request, env) {
  if (!env.ASC_WEBHOOK_SECRET) return json({ error: "webhooks are not set up here" }, 503);
  const raw = new Uint8Array(await request.arrayBuffer());
  if (raw.length > 64 * 1024) return json({ error: "too large" }, 413);
  if (!(await validSignature(env.ASC_WEBHOOK_SECRET, raw, request.headers.get("x-apple-signature")))) return json({ error: "bad signature" }, 401);
  let body;
  try {
    body = JSON.parse(new TextDecoder().decode(raw));
  } catch {
    return json({ error: "not JSON" }, 400);
  }
  const { item, eventId, at } = ascItem(body);
  const stub = queueV2(env) ? ascRelayStub(env) : null;
  if (stub) {
    const ingested = await stub.ingest({ eventId, at, item });
    if (!ingested?.ok) return json({ error: "could not persist" }, 500);
    if (mirrorKv(env)) {
      const key = `wh:${String(at).padStart(13, "0")}:${eventId}`;
      await env.OUTBOX.put(key, JSON.stringify(item), { expirationTtl: TTL });
    }
    return json({ ok: true, seq: ingested.seq });
  }
  const key = `wh:${String(at).padStart(13, "0")}:${eventId}`;
  await env.OUTBOX.put(key, JSON.stringify(item), { expirationTtl: TTL });
  return json({ ok: true });
}

async function outboxAsc(request, env, url) {
  if (!authed(request, env)) return json({ error: "unauthorized" }, 401);
  const since = Number(url.searchParams.get("since")) || 0;
  const items = [];
  let cursor;
  do {
    const page = await env.OUTBOX.list({ prefix: "wh:", cursor, limit: 500 });
    for (const k of page.keys) {
      if ((Number(String(k.name).slice(3, 16)) || 0) <= since) continue;
      const v = await env.OUTBOX.get(k.name);
      if (v) items.push({ key: k.name, ...JSON.parse(v) });
      if (items.length >= 200) break;
    }
    cursor = page.list_complete || items.length >= 200 ? undefined : page.cursor;
  } while (cursor);
  return json({ items });
}

async function ascEvents(request, env, url) {
  if (!authed(request, env)) return json({ error: "unauthorized" }, 401);
  const stub = ascRelayStub(env);
  if (!stub || !queueV2(env)) return json({ error: "asc event queue not enabled" }, 503);
  const afterSeq = Number(url.searchParams.get("after_seq")) || 0;
  const limit = Number(url.searchParams.get("limit")) || 200;
  const cursor = url.searchParams.get("cursor");
  if (cursor && !/^\d+$/.test(cursor)) return json({ error: "bad cursor" }, 400);
  const effectiveAfter = cursor ? Number(cursor) : afterSeq;
  return json(await stub.page({ afterSeq: effectiveAfter, limit }));
}

async function ascStream(request, env, url) {
  if (!authed(request, env)) return json({ error: "unauthorized" }, 401);
  if (request.headers.get("Upgrade") !== "websocket") return json({ error: "expected websocket" }, 426);
  const stub = ascRelayStub(env);
  if (!stub || !queueV2(env)) return json({ error: "asc event queue not enabled" }, 503);
  const relay = new URL(url);
  relay.pathname = "/";
  relay.searchParams.set("consumer", url.searchParams.get("consumer") || "mac-default");
  const after = url.searchParams.get("after_seq");
  if (after) relay.searchParams.set("after_seq", after);
  return stub.fetch(new Request(relay.toString(), request));
}

function ascCapabilities(env) {
  return json({
    code_version: WORKER_CODE_VERSION,
    asc_queue_v2: queueV2(env),
    kv_outbox: true,
    kv_import: env.ASC_KV_IMPORT === "1" || env.ASC_KV_IMPORT === "true",
    stream: "/asc/stream",
    events: "/asc/events",
    import: "/asc/import/kv",
    protocol: 2,
  });
}

async function ascImportKv(request, env, url) {
  if (!authed(request, env)) return json({ error: "unauthorized" }, 401);
  if (env.ASC_KV_IMPORT !== "1" && env.ASC_KV_IMPORT !== "true") return json({ error: "kv import disabled" }, 403);
  const stub = ascRelayStub(env);
  if (!stub || !queueV2(env)) return json({ error: "asc event queue not enabled" }, 503);
  if (request.method === "GET") {
    const cp = await stub.importCheckpoint("kv");
    return json({ checkpoint: cp });
  }
  if (request.method !== "POST") return json({ error: "method" }, 405);
  const budget = Math.min(Number(url.searchParams.get("budget")) || DEFAULT_IMPORT_BUDGET, 500);
  let cursor = url.searchParams.get("kv_cursor");
  if (cursor === "resume" || cursor === "") {
    const cp = await stub.importCheckpoint("kv");
    cursor = cp.kv_cursor || undefined;
  }
  const prior = await stub.importCheckpoint("kv");
  const page = await importKvPage({
    outbox: env.OUTBOX,
    stub,
    cursor,
    budget,
  });
  const total = (prior.imported_total || 0) + page.imported;
  await stub.saveImportCheckpoint({ source: "kv", kv_cursor: page.kv_cursor, imported_total: total });
  return json({ ...page, imported_total: total });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === "/asc/capabilities" && request.method === "GET") return ascCapabilities(env);
    if (url.pathname === "/asc/import/kv") return ascImportKv(request, env, url);
    if (url.pathname === "/asc/stream" && request.method === "GET") return ascStream(request, env, url);
    if (url.pathname === "/asc/events" && request.method === "GET") return ascEvents(request, env, url);
    if (url.pathname === "/asc" && request.method === "POST") return receiveAsc(request, env);
    if (url.pathname === "/asc/outbox" && request.method === "GET") return outboxAsc(request, env, url);
    if (url.pathname === "/apple" && request.method === "POST") return receive(request, env);
    if (url.pathname === "/outbox" && request.method === "GET") return outbox(request, env, url);
    if (url.pathname === "/" && request.method === "GET") return new Response("Hmunmawi live purchases is running.", { status: 200 });
    return json({ error: "not found" }, 404);
  },
};
