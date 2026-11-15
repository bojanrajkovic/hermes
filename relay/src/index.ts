import { Hono, type Context } from "hono";

export { Tenant } from "./tenant";

type App = { Bindings: Env };

const app = new Hono<App>();

const tenantID = /^[0-9a-f]{32}$/;

/** The Durable Object for the tenant named in the path, or undefined when the ID is malformed. */
function tenant(c: Context<App>) {
  const id = c.req.param("tenant") ?? "";
  return tenantID.test(id) ? c.env.TENANT.getByName(id) : undefined;
}

app.get("/version", (c) => c.json({ commit: c.env.COMMIT }));

const registrationStatus = {
  accepted: 201,
  invalid: 400,
  inviteRefused: 403,
  alreadyRegistered: 409,
} as const;

app.put("/tenants/:tenant", async (c) => {
  const stub = tenant(c);
  if (!stub) return c.notFound();

  const body: unknown = await c.req.json().catch(() => undefined);
  const outcome = await stub.register(body);
  return c.body(null, registrationStatus[outcome]);
});

export default app;
