import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { sign } from "@octokit/webhooks-methods";
import { describe, expect, it } from "vitest";

const registration = {
  invite: "first-code",
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

function register(tenant: string, body: unknown): Promise<Response> {
  return exports.default.fetch(`https://relay.test/tenants/${tenant}`, {
    method: "PUT",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function stored(tenant: string): Promise<unknown> {
  return runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) =>
    state.storage.get("registration"),
  );
}

describe("PUT /tenants/:tenant", () => {
  it("stores a registration", async () => {
    const tenant = newTenant();

    expect((await register(tenant, registration)).status).toBe(201);
    expect(await stored(tenant)).toEqual(registration);
  });

  it("stores nothing when the invite is refused", async () => {
    const tenant = newTenant();

    expect((await register(tenant, { ...registration, invite: "nope" })).status).toBe(403);
    expect(await stored(tenant)).toBeUndefined();
  });

  it("keeps the first registration", async () => {
    const tenant = newTenant();
    await register(tenant, registration);

    expect((await register(tenant, registration)).status).toBe(201);
    expect((await register(tenant, { ...registration, clientSecret: "other" })).status).toBe(409);
    expect(await stored(tenant)).toEqual(registration);
  });

  it("rejects a body that is not a registration", async () => {
    expect((await register(newTenant(), "{not json")).status).toBe(400);
    expect((await register(newTenant(), { invite: "first-code" })).status).toBe(400);
  });

  it("does not know a malformed tenant ID", async () => {
    expect((await register("ABC", registration)).status).toBe(404);
  });
});

describe("POST /hook/:tenant", () => {
  const secret = registration.webhookSecret;
  const pullRequest = JSON.stringify({ action: "opened", repository: { id: 7 } });

  async function deliver(
    tenant: string,
    event: string,
    body: string,
    signature?: string,
  ): Promise<Response> {
    return exports.default.fetch(`https://relay.test/hook/${tenant}`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-github-event": event,
        "x-hub-signature-256": signature ?? (await sign(secret, body)),
      },
      body,
    });
  }

  async function registered(): Promise<string> {
    const tenant = newTenant();
    await register(tenant, registration);
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

  it("deletes the tenant when its App is uninstalled", async () => {
    const tenant = await registered();
    const uninstalled = JSON.stringify({ action: "deleted", installation: { id: 1 } });

    expect((await deliver(tenant, "installation", uninstalled)).status).toBe(202);
    expect(await stored(tenant)).toBeUndefined();
    expect((await deliver(tenant, "pull_request", pullRequest)).status).toBe(404);
  });

  it("refuses deliveries once the tenant's invite code is withdrawn", async () => {
    const tenant = newTenant();
    await runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) =>
      state.storage.put("registration", { ...registration, invite: "withdrawn-code" }),
    );

    expect((await deliver(tenant, "pull_request", pullRequest)).status).toBe(403);
  });
});
