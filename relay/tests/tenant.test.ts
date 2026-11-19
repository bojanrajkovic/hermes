import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { sign } from "@octokit/webhooks-methods";
import { describe, expect, it } from "vitest";
import { newInvite } from "./invite";

const credentials = {
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

// Storage is shared within a file, so each test uses its own tenant.
let next = 0;
function newTenant(): string {
  next += 1;

  return next.toString(16).padStart(32, "0");
}

type Registration = typeof credentials & { invite: string };

/** A registration with an invite code nobody has used. */
async function newRegistration(): Promise<Registration> {
  return { ...credentials, invite: await newInvite() };
}

async function register(tenant: string, body: unknown): Promise<Response> {
  return await exports.default.fetch(`https://relay.test/tenants/${tenant}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function stored(tenant: string): Promise<unknown> {
  return await runInDurableObject(
    env.TENANT.getByName(tenant),
    async (_instance, state) => await state.storage.get("registration"),
  );
}

describe("PUT /tenants/:tenant", () => {
  it("stores a registration", async () => {
    const tenant = newTenant();
    const registration = await newRegistration();

    expect((await register(tenant, registration)).status).toBe(201);
    expect(await stored(tenant)).toEqual(registration);
  });

  it.each(["nope", "0".repeat(32)])(
    "stores nothing for the invite %j, which was never issued",
    async (invite) => {
      const tenant = newTenant();

      expect((await register(tenant, { ...credentials, invite })).status).toBe(403);
      expect(await stored(tenant)).toBeUndefined();
    },
  );

  it("registers one tenant with an invite", async () => {
    const registration = await newRegistration();
    const second = newTenant();
    await register(newTenant(), registration);

    expect((await register(second, registration)).status).toBe(403);
    expect(await stored(second)).toBeUndefined();
  });

  it("keeps the first registration", async () => {
    const tenant = newTenant();
    const registration = await newRegistration();
    await register(tenant, registration);

    expect((await register(tenant, registration)).status).toBe(201);
    expect((await register(tenant, { ...registration, clientSecret: "other" })).status).toBe(409);
    expect(await stored(tenant)).toEqual(registration);
  });

  it("rejects a body that is not a registration, and leaves its invite unused", async () => {
    const invite = await newInvite();

    expect((await register(newTenant(), "{not json")).status).toBe(400);
    expect((await register(newTenant(), { invite })).status).toBe(400);
    expect((await register(newTenant(), { ...credentials, invite })).status).toBe(201);
  });

  it("does not know a malformed tenant ID", async () => {
    expect((await register("ABC", await newRegistration())).status).toBe(404);
  });
});

describe("POST /invites", () => {
  async function issue(authorization?: string): Promise<Response> {
    return await exports.default.fetch("https://relay.test/invites", {
      method: "POST",
      headers: authorization === undefined ? {} : { authorization },
    });
  }

  it("gives the operator an invite that registers a tenant", async () => {
    const response = await issue("Bearer operator-token");
    const { invite } = await response.json<{ invite: string }>();

    expect(response.status).toBe(201);
    expect(invite).toMatch(/^[0-9a-f]{32}$/v);
    expect((await register(newTenant(), { ...credentials, invite })).status).toBe(201);
  });

  it.each([undefined, "Bearer ", "Bearer another-token", "operator-token"])(
    "refuses the authorization %j",
    async (authorization) => {
      expect((await issue(authorization)).status).toBe(401);
    },
  );
});

describe("POST /hook/:tenant", () => {
  const secret = credentials.webhookSecret;
  const pullRequest = JSON.stringify({ action: "opened", repository: { id: 7 } });

  async function deliver(
    tenant: string,
    event: string,
    body: string,
    signature?: string,
  ): Promise<Response> {
    return await exports.default.fetch(`https://relay.test/hook/${tenant}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-github-event": event,
        "x-hub-signature-256": signature ?? (await sign(secret, body)),
      },
      body,
    });
  }

  async function registered(registration?: unknown): Promise<string> {
    const tenant = newTenant();
    await register(tenant, registration ?? (await newRegistration()));

    return tenant;
  }

  it("accepts a delivery GitHub signed", async () => {
    const tenant = await registered();

    expect((await deliver(tenant, "pull_request", pullRequest)).status).toBe(202);
  });

  it("refuses a delivery signed with another secret, or not signed", async () => {
    const tenant = await registered();
    const forged = await sign("another-secret", pullRequest);

    expect((await deliver(tenant, "pull_request", pullRequest, forged)).status).toBe(401);
    expect((await deliver(tenant, "pull_request", pullRequest, "")).status).toBe(401);
  });

  it.each(["sha256=", "nope", "sha256=zz"])(
    "refuses the malformed signature %j",
    async (signature) => {
      const tenant = await registered();

      expect((await deliver(tenant, "pull_request", pullRequest, signature)).status).toBe(401);
    },
  );

  it("refuses a signed delivery whose body was changed", async () => {
    const tenant = await registered();
    const signature = await sign(secret, pullRequest);
    const changed = pullRequest.replace("7", "8");

    expect((await deliver(tenant, "pull_request", changed, signature)).status).toBe(401);
  });

  it("does not know a tenant that never registered", async () => {
    expect((await deliver(newTenant(), "pull_request", pullRequest)).status).toBe(404);
  });

  it("deletes the tenant when its App is uninstalled, and its invite stays used", async () => {
    const registration = await newRegistration();
    const tenant = await registered(registration);
    const uninstalled = JSON.stringify({ action: "deleted", installation: { id: 1 } });

    expect((await deliver(tenant, "installation", uninstalled)).status).toBe(202);
    expect(await stored(tenant)).toBeUndefined();
    expect((await deliver(tenant, "pull_request", pullRequest)).status).toBe(404);
    expect((await register(tenant, registration)).status).toBe(403);
  });
});
