import { env, createExecutionContext, waitOnExecutionContext, SELF } from "cloudflare:test";
import { describe, it, expect } from "vitest";
import worker, { validSignature } from "../../Resources/LiveWorker/worker.mjs";

const relay = "Bearer test-relay-key";
const ascSecret = "test-asc-secret";

async function ascPost(body, sig) {
  const ctx = createExecutionContext();
  const req = new Request("https://example/asc", {
    method: "POST",
    body,
    headers: { "x-apple-signature": sig },
  });
  const res = await worker.fetch(req, env, ctx);
  await waitOnExecutionContext(ctx);
  return res;
}

function ascBody(id, atMs) {
  return JSON.stringify({
    data: {
      type: "appStoreVersionAppVersionStateUpdated",
      id,
      attributes: {
        newValue: "READY_FOR_REVIEW",
        oldValue: "PREPARE_FOR_SUBMISSION",
        timestamp: new Date(atMs).toISOString(),
      },
      relationships: { instance: { data: { type: "appStoreVersions", id: "v1" } } },
    },
  });
}

async function sign(body) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(ascSecret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return "hmacsha256=" + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

describe("ASC durable relay", () => {
  it("persists before ACK and dedupes webhook id", async () => {
    const body = ascBody("evt-dup", Date.now());
    const sig = await sign(body);
    const a = await ascPost(body, sig);
    expect(a.status).toBe(200);
    const b = await ascPost(body, sig);
    expect(b.status).toBe(200);
    const page = await SELF.fetch("https://example/asc/events?after_seq=0", {
      headers: { authorization: relay },
    });
    const j = await page.json();
    expect(j.items.length).toBe(1);
    expect(j.items[0].id).toBe("evt-dup");
  });

  it("orders by seq and pages >200 without skipping", async () => {
    const seed = await SELF.fetch("https://example/asc/events?after_seq=0&limit=1", { headers: { authorization: relay } });
    const seedJ = await seed.json();
    const after0 = seedJ.next_seq ?? 0;
    const base = Date.now();
    for (let i = 0; i < 205; i++) {
      const body = ascBody(`burst-${i}`, base + i);
      const sig = await sign(body);
      const r = await ascPost(body, sig);
      expect(r.status).toBe(200);
    }
    let after = after0;
    let total = 0;
    let guard = 0;
    while (guard++ < 10) {
      const res = await SELF.fetch(`https://example/asc/events?after_seq=${after}&limit=200`, {
        headers: { authorization: relay },
      });
      const j = await res.json();
      total += j.items.length;
      if (!j.has_more) break;
      after = j.next_seq;
    }
    expect(total).toBe(205);
  });

  it("rejects unauthenticated event fetch", async () => {
    const res = await SELF.fetch("https://example/asc/events");
    expect(res.status).toBe(401);
  });

  it("validates cursor on event page", async () => {
    const res = await SELF.fetch("https://example/asc/events?cursor=not-a-seq", {
      headers: { authorization: relay },
    });
    expect(res.status).toBe(400);
  });

  it("legacy KV outbox is empty when v2 ingest only (no mirror)", async () => {
    const body = ascBody("kv-skip", Date.now());
    const sig = await sign(body);
    await ascPost(body, sig);
    const res = await SELF.fetch("https://example/asc/outbox", { headers: { authorization: relay } });
    const j = await res.json();
    expect(j.items.length).toBe(0);
  });

  it("capabilities advertise v2", async () => {
    const res = await SELF.fetch("https://example/asc/capabilities");
    const j = await res.json();
    expect(j.asc_queue_v2).toBe(true);
    expect(j.protocol).toBe(2);
  });

  it("rejects ack beyond delivered seq via RPC", async () => {
    const id = env.ASC_RELAY.idFromName("asc");
    const stub = env.ASC_RELAY.get(id);
    await stub.ingest({ eventId: "ack-rpc", at: 1, item: { id: "ack-rpc", at: 1, type: "t" } });
    const deny = await stub.ack({ consumerId: "rpc-c", seq: 1 });
    expect(deny.ok).toBe(false);
  });

  it("HMAC verification unchanged (Apple example)", async () => {
    const ok = await validSignature("This is my secret", new TextEncoder().encode("Hello, World!"), "hmacsha256=7f062172b01cb00b53ca068614674a3d982a34062a0f5d37687d5e3377e54657");
    expect(ok).toBe(true);
  });
});
