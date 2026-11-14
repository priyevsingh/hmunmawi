#!/usr/bin/env node
// Local deploy-shape check only (no upload). Requires devDependency wrangler from npm test install.
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.dirname(fileURLToPath(import.meta.url));
const toml = path.join(root, "wrangler.asc-test.toml");
const cfg = readFileSync(toml, "utf8");
const required = ["AscRelayDO", "ASC_RELAY", "new_sqlite_classes", "worker.mjs"];
const missing = required.filter((r) => !cfg.includes(r));
if (missing.length) {
  console.error("FAIL wrangler config missing", missing.join(", "));
  process.exit(1);
}
const wrangler = path.join(root, "node_modules", ".bin", "wrangler");
const dry = spawnSync(wrangler, ["deploy", "--dry-run", "--config", toml], { encoding: "utf8" });
if (dry.status !== 0) {
  console.error(dry.stderr || dry.stdout);
  process.exit(dry.status ?? 1);
}
if (!/AscRelayDO/.test(dry.stdout)) {
  console.error("FAIL dry-run output missing AscRelayDO export");
  process.exit(1);
}
console.log("ok  wrangler dry-run includes AscRelayDO");
