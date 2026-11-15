import { DurableObject } from "cloudflare:workers";
import { verify } from "@octokit/webhooks-methods";
import { classifyDelivery } from "./delivery";
import { refreshTokenForCode } from "./github";
import {
  decideRegistration,
  inviteAccepted,
  type Registration,
  type RegistrationDecision,
} from "./registration";

/** A webhook request as GitHub sent it. */
export type Delivery = {
  /** The `X-GitHub-Event` header. */
  event: string;
  /** The `X-Hub-Signature-256` header. */
  signature: string;
  /** The request body, unparsed, because the signature covers its exact bytes. */
  body: string;
};

export type DeliveryOutcome = "accepted" | "unknownTenant" | "badSignature" | "inviteRevoked";

export type SignIn =
  | { outcome: "signedIn"; refreshToken: string }
  | { outcome: "unknownTenant" }
  | { outcome: "refused" };

/** Whether GitHub signed this delivery with the tenant's webhook secret. */
async function signed(delivery: Delivery, secret: string): Promise<boolean> {
  // `verify` throws on an empty argument.
  if (delivery.signature === "" || delivery.body === "") return false;
  return verify(secret, delivery.body, delivery.signature);
}

/** One tenant: an account whose owner registered its own GitHub App with the relay. */
export class Tenant extends DurableObject<Env> {
  async register(body: unknown): Promise<RegistrationDecision["outcome"]> {
    const existing = await this.registration();
    const decision = decideRegistration(body, this.env.INVITE_CODES, existing);

    if (decision.outcome === "accepted") {
      await this.ctx.storage.put("registration", decision.registration);
    }
    return decision.outcome;
  }

  async deliver(delivery: Delivery): Promise<DeliveryOutcome> {
    const registration = await this.registration();
    if (!registration) return "unknownTenant";

    if (!(await signed(delivery, registration.webhookSecret))) return "badSignature";
    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) return "inviteRevoked";

    const action = classifyDelivery(delivery.event, delivery.body);
    if (action.action === "delete") await this.ctx.storage.deleteAll();
    return "accepted";
  }

  /** The tenant App's client ID, which GitHub's sign-in page needs. */
  async clientID(): Promise<string | undefined> {
    return (await this.registration())?.clientID;
  }

  /** Finishes a browser sign-in: trades GitHub's code for the user's refresh token. */
  async signIn(code: string, redirectURL: string): Promise<SignIn> {
    const registration = await this.registration();
    if (!registration) return { outcome: "unknownTenant" };
    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) return { outcome: "refused" };

    const refreshToken = await refreshTokenForCode(registration, code, redirectURL);
    return refreshToken ? { outcome: "signedIn", refreshToken } : { outcome: "refused" };
  }

  private registration(): Promise<Registration | undefined> {
    return this.ctx.storage.get<Registration>("registration");
  }
}
