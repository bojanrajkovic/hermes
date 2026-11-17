// Checks that the relay's Worker in Cloudflare has no setting that lets anything observe its
// requests: no Tail Worker, no log push, no observability, and only the bindings it should.
//
// Usage: node scripts/check-settings.ts
// Needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN. RELAY_WORKER names the Worker and
// defaults to hermes-relay.
import { settingsProblems } from "../src/worker-settings.ts";

const { CLOUDFLARE_ACCOUNT_ID: account = "", CLOUDFLARE_API_TOKEN: token = "" } = process.env;
const worker = process.env["RELAY_WORKER"] ?? "hermes-relay";
if (account === "" || token === "") {
  console.error(
    "usage: CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… node scripts/check-settings.ts",
  );
  process.exit(2);
}

const response = await fetch(
  `https://api.cloudflare.com/client/v4/accounts/${account}/workers/scripts/${worker}/settings`,
  { headers: { authorization: `Bearer ${token}` } },
);
if (!response.ok) {
  console.error(
    `Cloudflare answered ${String(response.status)} for ${worker}'s settings: ${await response.text()}`,
  );
  process.exit(1);
}

// Cloudflare wraps the settings: `{ "result": { … } }`.
const answer: unknown = await response.json();
const settings =
  typeof answer === "object" && answer !== null && "result" in answer ? answer.result : undefined;
const problems = settingsProblems(settings);
for (const problem of problems) {
  console.error(`${worker}: ${problem}`);
}

if (problems.length > 0) {
  process.exit(1);
}

console.log(`${worker}'s settings match the relay's`);
