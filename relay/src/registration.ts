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
  | { outcome: "accepted"; registration: Registration }
  | { outcome: "invalid" }
  | { outcome: "inviteRefused" }
  | { outcome: "alreadyRegistered" };

/** Whether `invite` is one of the comma-separated codes in `codes`. */
export function inviteAccepted(codes: string, invite: string): boolean {
  return codes
    .split(",")
    .map((code) => code.trim())
    .filter((code) => code !== "")
    .includes(invite);
}

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
  inviteCodes: string,
  existing: Registration | undefined,
): RegistrationDecision {
  const parsed = Registration.safeParse(body);
  if (!parsed.success) {
    return { outcome: "invalid" };
  }

  const registration = parsed.data;

  if (existing !== undefined) {
    const same = JSON.stringify(existing) === JSON.stringify(registration);

    return same ? { outcome: "accepted", registration } : { outcome: "alreadyRegistered" };
  }

  if (!inviteAccepted(inviteCodes, registration.invite)) {
    return { outcome: "inviteRefused" };
  }

  return { outcome: "accepted", registration };
}
