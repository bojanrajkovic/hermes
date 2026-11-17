import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { configDefaults, defineConfig } from "vitest/config";

// The tests' value for the INVITE_CODES secret, which wrangler reads from the environment.
process.env.INVITE_CODES = "first-code, second-code";

// The lint fixture test starts Oxlint, which needs Node.
const NODE = ["tests/lint/**/*.test.ts"];

export default defineConfig({
  test: {
    // Files and the tests in them run in a random order, so a test that relies on another having
    // run first fails. A failing run prints its seed; `--sequence.seed=<seed>` replays that order.
    sequence: { shuffle: true },
    projects: [
      // Runs inside the Workers runtime, with the bindings wrangler.jsonc declares.
      {
        extends: true,
        plugins: [cloudflareTest({ wrangler: { configPath: "./wrangler.jsonc" } })],
        test: {
          name: "worker",
          include: ["tests/**/*.test.ts"],
          exclude: [...configDefaults.exclude, ...NODE],
        },
      },
      { extends: true, test: { name: "node", include: NODE } },
    ],
  },
});
