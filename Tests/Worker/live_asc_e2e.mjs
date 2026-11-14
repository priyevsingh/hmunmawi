#!/usr/bin/env node
/**
 * Live hmunmawi-hooks e2e (harmless internal probe). Requires env HOOK_BASE (your worker URL), RELAY_KEY and ASC_SECRET; never logs them.
 */
const base = process.env.HOOK_BASE;
const relay = process.env.RELAY_KEY;
const secret = process.env.ASC_SECRET;
if (!base || !relay || !secret) {
  console.error("FAIL missing HOOK_BASE, RELAY_KEY or ASC_SECRET env");
  process.exit(1);
}

const probeId = "hm-live-probe-2026-11-07";
const body = JSON.stringify({
  data: {
    type: "appStoreVersionAppVersionStateUpdated",
    id: probeId,
    attributes: {
      newValue: "INTERNAL_PROBE",
      oldValue: "INTERNAL_PROBE",
      timestamp: new Date().toISOString(),
    },
    relationships: { instance: { data: { type: "appStoreVersions", id: "probe-instance" } } },
  },
});

async function sign(raw, sec) {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(sec), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
  return "hmacsha256=" + [...new Uint8Array(mac)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const caps = await fetch(`${base}/asc/capabilities`).then((r) => r.json());
console.log("capabilities", JSON.stringify(caps));
if (!caps.asc_queue_v2) {
  console.error("FAIL asc_queue_v2 false");
  process.exit(1);
}

const sig = await sign(body, secret);
const post = await fetch(`${base}/asc`, { method: "POST", body, headers: { "x-apple-signature": sig } });
console.log("asc_post", post.status);
if (post.status !== 200) {
  console.error("FAIL asc post", await post.text());
  process.exit(1);
}

const events = await fetch(`${base}/asc/events?after_seq=0&limit=50`, {
  headers: { authorization: `Bearer ${relay}` },
}).then((r) => r.json());
const found = events.items?.some((i) => i.id === probeId);
console.log("events_has_probe", found, "count", events.items?.length);
if (!found) {
  console.error("FAIL probe not in DO queue");
  process.exit(1);
}

const wsRes = await fetch(`${base}/asc/stream?consumer=live-e2e&after_seq=0`, {
  headers: { authorization: `Bearer ${relay}`, Upgrade: "websocket" },
});
if (wsRes.status !== 101 || !wsRes.webSocket) {
  console.error("FAIL websocket upgrade", wsRes.status);
  process.exit(1);
}
const ws = wsRes.webSocket;
ws.accept();
let got = false;
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error("ws timeout")), 15000);
  ws.addEventListener("message", (ev) => {
    try {
      const msg = JSON.parse(ev.data);
      if (msg.type === "event" && msg.item?.id === probeId) got = true;
      if (msg.type === "caught_up" || got) {
        clearTimeout(t);
        resolve();
      }
    } catch {
      /* ignore */
    }
  });
  ws.send(JSON.stringify({ type: "catchup", after_seq: 0 }));
});
ws.close(1000, "done");
console.log("websocket_probe", got);
if (!got) process.exit(1);
console.log("ok  live asc e2e");
