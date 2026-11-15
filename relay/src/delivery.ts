import { z } from "zod";

// The only fields of a GitHub payload the relay reads.
const Routing = z.object({
  action: z.string().optional(),
  repository: z.object({ id: z.number() }).nullish(),
});

export type DeliveryAction =
  /** Send the delivery to the sessions that can see this repository. */
  | { action: "forward"; repository: number }
  /** Someone's access may have changed: close every socket so each client is checked again. */
  | { action: "recheck" }
  /** The App was uninstalled: delete the tenant. */
  | { action: "delete" }
  | { action: "ignore" };

/** Events that change who can see which repositories. */
const accessEvents = new Set([
  "installation_repositories",
  "member",
  "membership",
  "organization",
  "repository",
  "team",
  "team_add",
]);

/** Decides what the relay does with a delivery whose signature has been verified. */
export function classifyDelivery(event: string, body: string): DeliveryAction {
  const parsed = Routing.safeParse(parseJSON(body));
  if (!parsed.success) return { action: "ignore" };
  const payload = parsed.data;

  if (event === "installation") {
    return payload.action === "deleted" ? { action: "delete" } : { action: "ignore" };
  }
  if (accessEvents.has(event)) return { action: "recheck" };
  if (payload.repository) return { action: "forward", repository: payload.repository.id };
  return { action: "ignore" };
}

function parseJSON(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return undefined;
  }
}
