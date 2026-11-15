import { Hono, type Context } from "hono";
import { z } from "zod";

export { Tenant } from "./tenant";

type App = { Bindings: Env };

const app = new Hono<App>();

// Hono's default handler prints the error. The relay prints nothing.
app.onError((_error, c) => c.body(null, 500));

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

const deliveryStatus = {
  accepted: 202,
  badSignature: 401,
  inviteRevoked: 403,
  unknownTenant: 404,
} as const;

app.post("/hook/:tenant", async (c) => {
  const stub = tenant(c);
  if (!stub) return c.notFound();

  const outcome = await stub.deliver({
    event: c.req.header("x-github-event") ?? "",
    id: c.req.header("x-github-delivery") ?? "",
    signature: c.req.header("x-hub-signature-256") ?? "",
    body: await c.req.text(),
  });
  return c.body(null, deliveryStatus[outcome]);
});

/** Where GitHub sends the browser after sign-in. It must match one of the App's callback URLs. */
function callbackURL(c: Context<App>): string {
  return `${new URL(c.req.url).origin}/t/${c.req.param("tenant")}/callback`;
}

app.get("/t/:tenant/login", async (c) => {
  const clientID = await tenant(c)?.clientID();
  if (!clientID) return c.notFound();

  const authorize = new URL("https://github.com/login/oauth/authorize");
  authorize.searchParams.set("client_id", clientID);
  authorize.searchParams.set("redirect_uri", callbackURL(c));
  authorize.searchParams.set("state", c.req.query("state") ?? "");
  return c.redirect(authorize.toString());
});

// GitHub's code goes to Hermes as the grant, untouched: the relay holds nothing between the
// browser's sign-in and the client's request for a session.
app.get("/t/:tenant/callback", (c) => {
  if (!tenant(c)) return c.notFound();
  const code = c.req.query("code");
  if (!code) return c.text("GitHub did not authorize the sign-in.", 400);

  const link = new URL("hermes://relay.session");
  link.searchParams.set("tenant", c.req.param("tenant"));
  link.searchParams.set("grant", code);
  link.searchParams.set("state", c.req.query("state") ?? "");
  return c.redirect(link.toString());
});

const SessionRequest = z.object({ grant: z.string().min(1) });

app.post("/t/:tenant/session", async (c) => {
  const stub = tenant(c);
  if (!stub) return c.notFound();
  const request = SessionRequest.safeParse(await c.req.json().catch(() => undefined));
  if (!request.success) return c.body(null, 400);

  const signIn = await stub.signIn(request.data.grant, callbackURL(c));
  switch (signIn.outcome) {
    case "signedIn":
      return c.json({ refreshToken: signIn.refreshToken });
    case "unknownTenant":
      return c.notFound();
    case "refused":
      return c.body(null, 403);
  }
});

app.get("/t/:tenant/connect", (c) => {
  const stub = tenant(c);
  if (!stub) return c.notFound();
  if (c.req.header("upgrade") !== "websocket") return c.body(null, 426);
  return stub.fetch(c.req.raw);
});

export default app;
