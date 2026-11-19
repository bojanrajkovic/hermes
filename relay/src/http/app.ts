import { Hono, type Context } from "hono";
import { timingSafeEqual } from "hono/utils/buffer";
import { invites } from "../invites";
import type { Tenant } from "../tenant";

type App = { Bindings: Env };

const app = new Hono<App>();

// Hono's default handler prints the error. The relay prints nothing.
app.onError((_error, c) => c.body(null, 500));

const tenantID = /^[0-9a-f]{32}$/v;

/** The Durable Object for the tenant named in the path, or undefined when the ID is malformed. */
function tenant(c: Context<App>): DurableObjectStub<Tenant> | undefined {
  const id = c.req.param("tenant") ?? "";

  return tenantID.test(id) ? c.env.TENANT.getByName(id) : undefined;
}

app.get("/version", (c) => c.json({ commit: c.env.COMMIT }));

// The operator's one call. It makes an invite code, and reads nothing a tenant stored.
app.post("/invites", async (c) => {
  const token = c.env.OPERATOR_TOKEN;
  const given = c.req.header("authorization") ?? "";
  // An unset token must not make `Bearer ` a password.
  if (token === "" || !(await timingSafeEqual(given, `Bearer ${token}`))) {
    return c.body(null, 401);
  }

  return c.json({ invite: await invites(c.env).issue() }, 201);
});

const registrationStatus = {
  accepted: 201,
  invalid: 400,
  inviteRefused: 403,
  alreadyRegistered: 409,
} as const;

app.put("/tenants/:tenant", async (c) => {
  const stub = tenant(c);
  if (stub === undefined) {
    return await c.notFound();
  }

  const body: unknown = await c.req.json().catch(() => undefined);
  const outcome = await stub.register(body);

  return c.body(null, registrationStatus[outcome]);
});

const deliveryStatus = {
  accepted: 202,
  badSignature: 401,
  unknownTenant: 404,
} as const;

app.post("/hook/:tenant", async (c) => {
  const stub = tenant(c);
  if (stub === undefined) {
    return await c.notFound();
  }

  const outcome = await stub.deliver({
    event: c.req.header("x-github-event") ?? "",
    id: c.req.header("x-github-delivery") ?? "",
    signature: c.req.header("x-hub-signature-256") ?? "",
    body: await c.req.text(),
  });

  return c.body(null, deliveryStatus[outcome]);
});

export default app;
