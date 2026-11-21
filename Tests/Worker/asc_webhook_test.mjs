import worker, { validSignature } from "../../Resources/LiveWorker/workerCore.mjs";
const kv = new Map();
const env = { RELAY_KEY: "k", ASC_WEBHOOK_SECRET: "This is my secret",
  OUTBOX: { put: async (k, v) => kv.set(k, v), get: async (k) => kv.get(k) ?? null,
            list: async ({ prefix }) => ({ keys: [...kv.keys()].filter((k) => k.startsWith(prefix)).map((name) => ({ name })), list_complete: true }) } };
let ok = true; const check = (n, c) => { console.log(c ? "ok  " : "FAIL", n); if (!c) ok = false; };
// Apple's documented example: secret "This is my secret", body "Hello, World!"
const sig = "hmacsha256=7f062172b01cb00b53ca068614674a3d982a34062a0f5d37687d5e3377e54657";
check("Apple's example verifies", await validSignature("This is my secret", new TextEncoder().encode("Hello, World!"), sig));
check("wrong body refused", !(await validSignature("This is my secret", new TextEncoder().encode("Hello, World?"), sig)));
check("wrong secret refused", !(await validSignature("other", new TextEncoder().encode("Hello, World!"), sig)));
check("garbage header refused", !(await validSignature("s", new Uint8Array(1), "hmacsha256=zz")));
const body = JSON.stringify({ data: { type: "appStoreVersionAppVersionStateUpdated", id: "7c81", attributes: { newValue: "READY_FOR_REVIEW", oldValue: "PREPARE_FOR_SUBMISSION", timestamp: "2025-04-16T05:00:52.745Z" }, relationships: { instance: { data: { type: "appStoreVersions", id: "ad7e" } } } } });
const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(env.ASC_WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
const good = "hmacsha256=" + [...new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body)))].map((b) => b.toString(16).padStart(2, "0")).join("");
let r = await worker.fetch(new Request("https://x/asc", { method: "POST", body, headers: { "x-apple-signature": good } }), env);
check("signed notification accepted", r.status === 200 && kv.size === 1);
r = await worker.fetch(new Request("https://x/asc", { method: "POST", body, headers: { "x-apple-signature": "hmacsha256=" + "0".repeat(64) } }), env);
check("bad signature refused with 401, nothing stored", r.status === 401 && kv.size === 1);
r = await worker.fetch(new Request("https://x/asc", { method: "POST", body }), env);
check("no signature refused", r.status === 401);
r = await worker.fetch(new Request("https://x/asc", { method: "POST", body, headers: { "x-apple-signature": good } }), { ...env, ASC_WEBHOOK_SECRET: undefined });
check("not set up -> 503", r.status === 503);
r = await worker.fetch(new Request("https://x/asc/outbox"), env);
check("outbox needs the key", r.status === 401);
r = await worker.fetch(new Request("https://x/asc/outbox", { headers: { authorization: "Bearer k" } }), env);
const j = await r.json();
check("outbox returns the facts only", j.items.length === 1 && j.items[0].from === "PREPARE_FOR_SUBMISSION" && j.items[0].to === "READY_FOR_REVIEW" && j.items[0].instanceId === "ad7e" && !JSON.stringify(j).includes("secret"));
r = await worker.fetch(new Request("https://x/outbox", { headers: { authorization: "Bearer k" } }), env);
check("purchase outbox untouched (no webhook items)", (await r.json()).items.length === 0);
r = await worker.fetch(new Request("https://x/", {}), env);
check("root still answers", r.status === 200);

// Live sales (/apple): nothing is taken without the app list, and a body over 64 KB is refused before it's read as JSON.
r = await worker.fetch(new Request("https://x/apple", { method: "POST", body: JSON.stringify({ signedPayload: "x" }) }), env);
check("/apple without BUNDLE_IDS -> 503", r.status === 503);
r = await worker.fetch(new Request("https://x/apple", { method: "POST", body: "x".repeat(65 * 1024) }), { ...env, BUNDLE_IDS: "com.example.app" });
check("/apple over 64 KB -> 413", r.status === 413);
r = await worker.fetch(new Request("https://x/apple", { method: "POST", body: "{not json" }), { ...env, BUNDLE_IDS: "com.example.app" });
check("/apple bad JSON -> 400", r.status === 400);
r = await worker.fetch(new Request("https://x/apple", { method: "POST", body: JSON.stringify({ signedPayload: "a.b.c" }) }), { ...env, BUNDLE_IDS: "com.example.app" });
check("/apple unsigned payload refused", r.status >= 400 && r.status < 500);
// The hooks worker has no BUNDLE_IDS: its /asc paths and capabilities keep working, and it reports its code version.
r = await worker.fetch(new Request("https://x/asc/capabilities", { headers: { authorization: "Bearer k" } }), env);
const caps = r.status === 200 ? await r.json() : {};
check("capabilities without BUNDLE_IDS: 200 with code_version", r.status === 200 && Number.isInteger(caps.code_version) && caps.code_version >= 2);
r = await worker.fetch(new Request("https://x/asc", { method: "POST", body, headers: { "x-apple-signature": good } }), env);
check("/asc still accepted without BUNDLE_IDS", r.status === 200);
process.exit(ok ? 0 : 1);
