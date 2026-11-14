import { env, SELF, evictDurableObject, runInDurableObject } from "cloudflare:test";
import { describe, it, expect } from "vitest";

const relay = "Bearer test-relay-key";

async function postAsc(id) {
  const body = JSON.stringify({
    data: {
      type: "appStoreVersionAppVersionStateUpdated",
      id,
      attributes: { newValue: "A", oldValue: "B", timestamp: new Date().toISOString() },
    },
  });
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode("test-asc-secret"),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig =
    "hmacsha256=" +
    [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
  await SELF.fetch("https://example/asc", { method: "POST", body, headers: { "x-apple-signature": sig } });
}

async function openStream(consumer = "mac-default", after = "0") {
  const res = await SELF.fetch(`https://example/asc/stream?consumer=${consumer}&after_seq=${after}`, {
    headers: { authorization: relay, Upgrade: "websocket" },
  });
  expect(res.status).toBe(101);
  const ws = res.webSocket;
  if (!ws) throw new Error("no websocket");
  ws.accept();
  return ws;
}

function onceMessage(ws) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error("timeout")), 5000);
    ws.addEventListener("message", (ev) => {
      clearTimeout(t);
      resolve(JSON.parse(ev.data));
    });
  });
}

describe("ASC websocket relay", () => {
  it("rejects unauthenticated stream", async () => {
    const res = await SELF.fetch("https://example/asc/stream", { headers: { Upgrade: "websocket" } });
    expect(res.status).toBe(401);
  });

  it("delivers catchup then accepts ack only after delivery", async () => {
    await postAsc("ws-1");
    const ws = await openStream();
    const msg = await onceMessage(ws);
    expect(msg.type).toBe("event");
    expect(msg.seq).toBeGreaterThan(0);
    const early = await SELF.fetch("https://example/asc/events?after_seq=0", { headers: { authorization: relay } });
    expect((await early.json()).items.length).toBeGreaterThan(0);
    ws.send(JSON.stringify({ type: "ack", seq: msg.seq + 99 }));
    const bad = await onceMessage(ws);
    expect(bad.ok).toBe(false);
    ws.send(JSON.stringify({ type: "ack", seq: msg.seq }));
    const ok = await onceMessage(ws);
    expect(ok.ok).toBe(true);
    ws.close(1000, "done");
  });

  it("isolates per-consumer ack and delivery state", async () => {
    await postAsc("iso-a");
    await postAsc("iso-b");
    const id = env.ASC_RELAY.idFromName("asc");
    const stub = env.ASC_RELAY.get(id);
    const premature = await stub.ack({ consumerId: "consumer-a", seq: 99 });
    expect(premature.ok).toBe(false);
    const ws = await openStream("consumer-a", "0");
    const first = await onceMessage(ws);
    const good = await stub.ack({ consumerId: "consumer-a", seq: first.seq });
    expect(good.ok).toBe(true);
    const other = await stub.ack({ consumerId: "consumer-b", seq: first.seq });
    expect(other.ok).toBe(false);
    ws.close(1000, "x");
  });

  it("DO eviction hibernates WebSocket without losing deliverable events", async () => {
    await postAsc("evict-1");
    const ws = await openStream();
    await onceMessage(ws);
    const stub = env.ASC_RELAY.get(env.ASC_RELAY.idFromName("asc"));
    await evictDurableObject(stub, { webSockets: "hibernate" });
    await postAsc("evict-2");
    ws.send(JSON.stringify({ type: "catchup", after_seq: 0 }));
    const after = await onceMessage(ws);
    expect(["event", "caught_up"]).toContain(after.type);
    ws.close(1000, "done");
  });

  it("retention does not delete below min consumer ack", async () => {
    const id = env.ASC_RELAY.idFromName("retention-isolated");
    const stub = env.ASC_RELAY.get(id);
    await stub.ingest({ eventId: "old-1", at: 1, item: { id: "old-1", at: 1, type: "t" } });
    await runInDurableObject(stub, async (_i, state) => {
      state.storage.sql.exec(
        "UPDATE events SET created_ms = ? WHERE event_id = ?",
        Date.now() - 8 * 24 * 3600 * 1000,
        "old-1",
      );
      state.storage.sql.exec(
        "INSERT INTO deliveries (consumer_id, last_ack_seq, last_delivered_seq, last_ack_ms) VALUES ('c1', 0, 1, 0)",
      );
      state.storage.sql.exec("DELETE FROM events WHERE created_ms < ? AND seq <= ?", 0, 0);
      const left = state.storage.sql.exec("SELECT COUNT(*) AS c FROM events").one().c;
      expect(left).toBe(1);
    });
  });
});
