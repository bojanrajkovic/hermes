// What the relay's Worker must look like in Cloudflare, apart from its script. The verify
// workflow runs this against the deployed Worker's settings. It is not part of the Worker.
//
// The script's hash says what code runs. These settings decide what else can observe a
// request: a Tail Worker or log push receives each request's address and headers, and a
// binding gives the code somewhere to send data.

type Binding = { name?: unknown; type?: unknown };

const expectedBindings = ["COMMIT:plain_text", "INVITE_CODES:secret_text", "TENANT:durable_object_namespace"];

/** The ways a Worker's settings differ from the relay's. Empty when they match. */
export function settingsProblems(settings: unknown): string[] {
  if (typeof settings !== "object" || settings === null) return ["Cloudflare returned no settings"];
  const record = settings as Record<string, unknown>;
  const problems: string[] = [];

  // Cloudflare has more than one kind of tail consumer, so every setting named for one counts.
  for (const [key, value] of Object.entries(record)) {
    if (/tail/i.test(key) && Array.isArray(value) && value.length > 0) {
      problems.push(`${key} is set: ${JSON.stringify(value)}`);
    }
  }
  if (record["logpush"] === true) problems.push("logpush is on");
  if (enabled(record["observability"])) problems.push("observability is on");

  const bindings = Array.isArray(record["bindings"]) ? (record["bindings"] as Binding[]) : [];
  const found = bindings.map((binding) => `${String(binding.name)}:${String(binding.type)}`).sort();
  if (JSON.stringify(found) !== JSON.stringify(expectedBindings)) {
    problems.push(`bindings are ${JSON.stringify(found)}, not ${JSON.stringify(expectedBindings)}`);
  }
  return problems;
}

/** Whether an observability setting, or its logs or traces part, is switched on. */
function enabled(observability: unknown): boolean {
  if (typeof observability !== "object" || observability === null) return false;
  const { enabled, logs, traces } = observability as Record<string, unknown>;
  return enabled === true || [logs, traces].some((part) => isOn(part));
}

function isOn(part: unknown): boolean {
  return typeof part === "object" && part !== null && (part as Record<string, unknown>)["enabled"] === true;
}
