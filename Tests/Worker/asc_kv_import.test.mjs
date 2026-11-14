import { env, createExecutionContext, waitOnExecutionContext, SELF } from "cloudflare:test";
import { describe, it, expect, beforeEach } from "vitest";
import worker from "../../Resources/LiveWorker/workerCore.mjs";
import { kvItemToIngest, parseWhKey, importKvPage } from "../../Resources/LiveWorker/ascKvImport.mjs";

const relay = "Bearer test-relay-key";

async function seedKv(entries) {
  for (const [k, v] of entries) await env.OUTBOX.put(k, JSON.stringify(v));
}

describe("KV import helpers", () => {
  it("parses wh keys", () => {
    const p = parseWhKey("wh:0000000001234:abc");
    expect(p?.at).toBe(1234);
    expect(p?.eventId).toBe("abc");
  });

  it("normalizes ingest payloads", () => {
    const r = kvItemToIngest("wh:0000000001000:e1", { type: "x", id: "e1", at: 1000 });
    expect(r.ok).toBe(true);
    expect(r.eventId).toBe("e1");
  });
});

describe("bounded KV -> DO import (mocked KV)", () => {
  beforeEach(async () => {
    // fresh kv per isolated test file runtime
  });

  it("requires auth and import flag", async () => {
    const r = await SELF.fetch("https://example/asc/import/kv", { method: "POST" });
    expect(r.status).toBe(401);
    const denied = await SELF.fetch("https://example/asc/import/kv", {
      method: "POST",
      headers: { authorization: "Bearer wrong" },
    });
    expect(denied.status).toBe(401);
  });

  it("imports with checkpoint resume and idempotent dedupe", async () => {
    await seedKv([
      ["wh:0000000000001:a", { id: "a", at: 1, type: "t" }],
      ["wh:0000000000001:b", { id: "b", at: 1, type: "t" }],
      ["wh:0000000000002:c", { id: "c", at: 2, type: "t" }],
    ]);
    const h = { authorization: relay };
    const first = await SELF.fetch("https://example/asc/import/kv?budget=2", { method: "POST", headers: h });
    expect(first.status).toBe(200);
    const j1 = await first.json();
    expect(j1.imported).toBe(2);
    expect(j1.list_complete).toBe(false);
    const second = await SELF.fetch("https://example/asc/import/kv?kv_cursor=resume", { method: "POST", headers: h });
    const j2 = await second.json();
    expect(j2.imported + j2.duplicates).toBeGreaterThan(0);
    const page = await SELF.fetch("https://example/asc/events?after_seq=0", { headers: h });
    const items = (await page.json()).items;
    const ids = new Set(items.map((i) => i.id));
    expect(ids.has("a") && ids.has("b") && ids.has("c")).toBe(true);
    // re-run import does not grow unique events
    const again = await SELF.fetch("https://example/asc/import/kv?kv_cursor=resume", { method: "POST", headers: h });
    const j3 = await again.json();
    expect(j3.duplicates).toBeGreaterThan(0);
    expect((await SELF.fetch("https://example/asc/events?after_seq=0", { headers: h }).then((r) => r.json())).items.length).toBe(3);
  });
});
