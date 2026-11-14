import path from "node:path";
import { fileURLToPath } from "node:url";
import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

const root = path.dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: path.join(root, "wrangler.asc-test.toml") },
    }),
  ],
  test: {
    include: ["asc_relay_do.test.mjs", "asc_kv_import.test.mjs", "asc_relay_websocket.test.mjs"],
  },
});
