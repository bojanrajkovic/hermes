import { env } from "cloudflare:workers";

/** An invite code nobody has used, as `POST /invites` would hand the operator. */
export async function newInvite(): Promise<string> {
  return await env.INVITES.getByName("invites").issue();
}
