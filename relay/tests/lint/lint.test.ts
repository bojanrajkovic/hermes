import { spawnSync } from "node:child_process";
import path from "node:path";
import { expect, it } from "vitest";
import { z } from "zod";

const OXLINT = path.resolve("node_modules/oxlint/bin/oxlint");
const FIXTURE = "tests/lint/fixtures/violations.ts";

const Report = z.object({ diagnostics: z.array(z.object({ code: z.string() })) });

// Oxlint runs the return-type rule and @stylistic as JS plugins, which it marks alpha. A release
// that stopped one of them reporting would still pass `pnpm lint`, so this pins what the fixture's
// deliberate violations produce.
it("reports each violation in the lint fixture", () => {
  const run = spawnSync(process.execPath, [OXLINT, "--format", "json", FIXTURE], {
    encoding: "utf8",
  });
  const { diagnostics } = Report.parse(JSON.parse(run.stdout));

  const counts = Object.fromEntries(
    Object.entries(Object.groupBy(diagnostics, ({ code }) => code)).map(([code, found]) => [
      code,
      found?.length,
    ]),
  );
  expect(counts).toEqual({
    "@stylistic(padding-line-between-statements)": 3,
    "eslint(curly)": 1,
    "eslint(init-declarations)": 1,
    "eslint(max-params)": 1,
    "eslint(no-unused-vars)": 3,
    "eslint(prefer-const)": 1,
    "eslint(prefer-destructuring)": 1,
    "eslint(require-unicode-regexp)": 1,
    "eslint-js(no-restricted-syntax)": 1,
    "typescript(consistent-type-definitions)": 1,
    "typescript(explicit-function-return-type)": 1,
    "typescript(method-signature-style)": 1,
    "typescript(no-floating-promises)": 1,
    "typescript(no-unnecessary-condition)": 1,
    "typescript(no-unsafe-type-assertion)": 2,
    "typescript(prefer-nullish-coalescing)": 1,
    "typescript(promise-function-async)": 1,
    "typescript(require-array-sort-compare)": 1,
    "typescript(return-await)": 1,
    "typescript(strict-boolean-expressions)": 3,
    "typescript(switch-exhaustiveness-check)": 1,
  });
});
