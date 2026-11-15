import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The tests' value for the INVITE_CODES secret, which wrangler reads from the environment.
process.env.INVITE_CODES = "first-code, second-code";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
});
