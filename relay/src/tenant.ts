import { DurableObject } from "cloudflare:workers";
import { verify } from "@octokit/webhooks-methods";
import { classifyDelivery } from "./delivery";
import { invites } from "./invites";
import { decideRegistration, type Registration } from "./registration";

/** A webhook request as GitHub sent it. */
export type Delivery = {
  /** The `X-GitHub-Event` header. */
  event: string;
  /** The `X-GitHub-Delivery` header. */
  id: string;
  /** The `X-Hub-Signature-256` header. */
  signature: string;
  /** The request body, unparsed, because the signature covers its exact bytes. */
  body: string;
};

export type RegistrationOutcome = "accepted" | "invalid" | "inviteRefused" | "alreadyRegistered";

export type DeliveryOutcome = "accepted" | "unknownTenant" | "badSignature";

/** Whether GitHub signed this delivery with the tenant's webhook secret. */
async function signed(delivery: Delivery, secret: string): Promise<boolean> {
  // `verify` throws on an empty argument, and on a signature that is not `sha256=<hex>`.
  if (delivery.signature === "" || delivery.body === "") {
    return false;
  }

  try {
    return await verify(secret, delivery.body, delivery.signature);
  } catch {
    return false;
  }
}

/** One tenant: an account whose owner registered its own GitHub App with the relay. */
export class Tenant extends DurableObject<Env> {
  async register(body: unknown): Promise<RegistrationOutcome> {
    const decision = decideRegistration(body, await this.registration());
    switch (decision.outcome) {
      case "invalid":
      case "alreadyRegistered":
        return decision.outcome;
      case "repeated":
        return "accepted";
      case "first":
        // shortcut: a failure between using the code and storing the registration leaves the
        // owner needing another code. Keep the tenant's ID with the code if that ever happens.
        if (!(await invites(this.env).redeem(decision.registration.invite))) {
          return "inviteRefused";
        }

        await this.ctx.storage.put("registration", decision.registration);

        return "accepted";
    }
  }

  async deliver(delivery: Delivery): Promise<DeliveryOutcome> {
    const registration = await this.registration();
    if (registration === undefined) {
      return "unknownTenant";
    }

    if (!(await signed(delivery, registration.webhookSecret))) {
      return "badSignature";
    }

    const action = classifyDelivery(delivery.event, delivery.body);
    switch (action.action) {
      case "forward":
        break;
      case "recheck":
        break;
      case "delete":
        await this.ctx.storage.deleteAll();
        break;
      case "ignore":
        break;
    }

    return "accepted";
  }

  private async registration(): Promise<Registration | undefined> {
    return await this.ctx.storage.get<Registration>("registration");
  }
}
