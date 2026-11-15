import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
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
