// What the relay's Worker must look like in Cloudflare, apart from its script. The verify
// workflow runs this against the deployed Worker's settings. It is not part of the Worker.
//
// The script's hash says what code runs. These settings decide what else can observe a
// request: a Tail Worker or log push receives each request's address and headers, and a
// binding gives the code somewhere to send data.

const expectedBindings = [
  "COMMIT:plain_text",
  "INVITE_CODES:secret_text",
  "TENANT:durable_object_namespace",
];

/** Whether a value from Cloudflare's JSON has properties to read. */
function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

/** Orders strings by code unit, the order `expectedBindings` is written in. */
function byCodeUnit(a: string, b: string): number {
  if (a === b) {
    return 0;
  }

  return a < b ? -1 : 1;
}

/** A binding as `name:type`, the form `expectedBindings` uses. */
function bindingName(binding: unknown): string {
  return isRecord(binding)
    ? `${String(binding["name"])}:${String(binding["type"])}`
    : String(binding);
}

/** The ways a Worker's settings differ from the relay's. Empty when they match. */
export function settingsProblems(settings: unknown): string[] {
  if (!isRecord(settings)) {
    return ["Cloudflare returned no settings"];
  }

  const problems: string[] = [];

  // Cloudflare has more than one kind of tail consumer, so every setting named for one counts.
  for (const [key, value] of Object.entries(settings)) {
    if (/tail/iv.test(key) && Array.isArray(value) && value.length > 0) {
      problems.push(`${key} is set: ${JSON.stringify(value)}`);
    }
  }

  if (settings["logpush"] === true) {
    problems.push("logpush is on");
  }

  if (enabled(settings["observability"])) {
    problems.push("observability is on");
  }

  const bindings: unknown[] = Array.isArray(settings["bindings"]) ? settings["bindings"] : [];
  const found = bindings.map((binding) => bindingName(binding)).sort(byCodeUnit);
  if (JSON.stringify(found) !== JSON.stringify(expectedBindings)) {
    problems.push(`bindings are ${JSON.stringify(found)}, not ${JSON.stringify(expectedBindings)}`);
  }

  return problems;
}

/** Whether an observability setting, or its logs or traces part, is switched on. */
function enabled(observability: unknown): boolean {
  if (!isRecord(observability)) {
    return false;
  }

  const { enabled, logs, traces } = observability;

  return enabled === true || [logs, traces].some((part) => isOn(part));
}

function isOn(part: unknown): boolean {
  return isRecord(part) && part["enabled"] === true;
}
