import { z } from "zod";

const Registration = z.object({
  invite: z.string().min(1),
  appID: z.number().int().positive(),
  clientID: z.string().min(1),
  clientSecret: z.string().min(1),
  webhookSecret: z.string().min(1),
});

/** What a tenant's owner sends once: an invite code and the tenant App's credentials. */
export type Registration = z.infer<typeof Registration>;

export type RegistrationDecision =
  | { outcome: "invalid" }
  | { outcome: "alreadyRegistered" }
  /** The stored registration, sent again. */
  | { outcome: "repeated" }
  /** A tenant's first registration. It is stored once its invite code has been used up. */
  | { outcome: "first"; registration: Registration };

/**
 * Decides what to do with a registration request.
 *
 * A tenant registers once. Sending the stored registration again is accepted,
 * so an owner whose first request succeeded but whose connection dropped can
 * retry. Anything else sent to a registered tenant is refused, so nobody who
 * learns a tenant's ID can replace its credentials.
 */
export function decideRegistration(
  body: unknown,
  existing: Registration | undefined,
): RegistrationDecision {
  const parsed = Registration.safeParse(body);
  if (!parsed.success) {
    return { outcome: "invalid" };
  }

  const registration = parsed.data;

  if (existing === undefined) {
    return { outcome: "first", registration };
  }

  const same = JSON.stringify(existing) === JSON.stringify(registration);

  return same ? { outcome: "repeated" } : { outcome: "alreadyRegistered" };
}
