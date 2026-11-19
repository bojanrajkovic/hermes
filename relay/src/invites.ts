import { DurableObject } from "cloudflare:workers";

const inviteCode = /^[0-9a-f]{32}$/v;

/**
 * The invite codes the operator has issued that nobody has used yet. The relay has one of
 * these objects. A code registers one tenant, because using a code deletes it.
 */
export class Invites extends DurableObject<Env> {
  /** Makes a code for the operator to give to a tenant's owner. */
  async issue(): Promise<string> {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    const invite = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
    await this.ctx.storage.put(invite, true);

    return invite;
  }

  /** Uses a code up. False when the relay never issued it, or it has been used. */
  async redeem(invite: string): Promise<boolean> {
    // Only a string shaped like a code is looked up: storage refuses a key over its size limit.
    return inviteCode.test(invite) && (await this.ctx.storage.delete(invite));
  }
}

/** The relay's one `Invites` object. */
export function invites(env: Env): DurableObjectStub<Invites> {
  return env.INVITES.getByName("invites");
}
