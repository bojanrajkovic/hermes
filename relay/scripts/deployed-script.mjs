// Downloads the script Cloudflare is running for the relay and writes it to a file, so its
// hash can be checked against the attested bundle.
//
// Usage: node scripts/deployed-script.mjs <output file>
// Needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_API_TOKEN. RELAY_WORKER names the Worker and
// defaults to hermes-relay.
import { writeFile } from "node:fs/promises";

const [output] = process.argv.slice(2);
const { CLOUDFLARE_ACCOUNT_ID: account, CLOUDFLARE_API_TOKEN: token } = process.env;
const worker = process.env.RELAY_WORKER ?? "hermes-relay";
if (!output || !account || !token) {
  console.error("usage: CLOUDFLARE_ACCOUNT_ID=… CLOUDFLARE_API_TOKEN=… node scripts/deployed-script.mjs <output file>");
  process.exit(2);
}

const response = await fetch(
  `https://api.cloudflare.com/client/v4/accounts/${account}/workers/scripts/${worker}/content/v2`,
  { headers: { authorization: `Bearer ${token}` } },
);
if (!response.ok) {
  console.error(`Cloudflare answered ${response.status} for ${worker}: ${await response.text()}`);
  process.exit(1);
}

// The answer is multipart: one part per module, and the cf-entrypoint header names the main one.
const entrypoint = response.headers.get("cf-entrypoint");
const script = entrypoint && (await response.formData()).get(entrypoint);
if (!script || typeof script === "string") {
  console.error(`Cloudflare's answer has no module named ${entrypoint}`);
  process.exit(1);
}

await writeFile(output, Buffer.from(await script.arrayBuffer()));
console.log(`wrote ${entrypoint} (${script.size} bytes) to ${output}`);
