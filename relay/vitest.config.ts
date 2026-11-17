import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The tests' value for the INVITE_CODES secret, which wrangler reads from the environment.
process.env.INVITE_CODES = "first-code, second-code";

export default defineConfig({
  plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
  test: {
    // Files and the tests in them run in a random order, so a test that relies on another having
    // run first fails. A failing run prints its seed; `--sequence.seed=<seed>` replays that order.
    sequence: { shuffle: true },
  },
});
