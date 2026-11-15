import { DurableObject } from "cloudflare:workers";
import { decideRegistration, type Registration, type RegistrationDecision } from "./registration";

/** One tenant: an account whose owner registered its own GitHub App with the relay. */
export class Tenant extends DurableObject<Env> {
  async register(body: unknown): Promise<RegistrationDecision["outcome"]> {
    const existing = await this.ctx.storage.get<Registration>("registration");
    const decision = decideRegistration(body, this.env.INVITE_CODES, existing);

    if (decision.outcome === "accepted") {
      await this.ctx.storage.put("registration", decision.registration);
    }
    return decision.outcome;
  }
}
