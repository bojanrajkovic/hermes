import { Hono, type Context } from "hono";
import { timingSafeEqual } from "hono/utils/buffer";
import { z } from "zod";
import { invites } from "../invites";
import { CodeChallenge, CodeVerifier } from "../session";
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

/** Where GitHub sends the browser after sign-in. It must match one of the App's callback URLs. */
function callbackURL(c: Context<App>): string {
  return `${new URL(c.req.url).origin}/t/${c.req.param("tenant") ?? ""}/callback`;
}

app.get("/t/:tenant/login", async (c) => {
  const clientID = await tenant(c)?.clientID();
  if (clientID === undefined) {
    return await c.notFound();
  }

  // The client keeps the verifier for this challenge and sends it with the grant.
  const challenge = CodeChallenge.safeParse(c.req.query("code_challenge"));
  if (!challenge.success) {
    return c.body(null, 400);
  }

  const authorize = new URL("https://github.com/login/oauth/authorize");
  authorize.searchParams.set("client_id", clientID);
  authorize.searchParams.set("redirect_uri", callbackURL(c));
  authorize.searchParams.set("state", c.req.query("state") ?? "");
  authorize.searchParams.set("code_challenge", challenge.data);
  authorize.searchParams.set("code_challenge_method", "S256");

  return c.redirect(authorize.toString());
});

// GitHub's code goes to Hermes as the grant, untouched: the relay holds nothing between the
// browser's sign-in and the client's request for a session.
app.get("/t/:tenant/callback", async (c) => {
  if (tenant(c) === undefined) {
    return await c.notFound();
  }

  const code = c.req.query("code");
  if (code === undefined || code === "") {
    return c.text("GitHub did not authorize the sign-in.", 400);
  }

  const link = new URL("hermes://relay.session");
  link.searchParams.set("tenant", c.req.param("tenant"));
  link.searchParams.set("grant", code);
  link.searchParams.set("state", c.req.query("state") ?? "");

  return c.redirect(link.toString());
});

const SessionRequest = z.object({ grant: z.string().min(1), verifier: CodeVerifier });

app.post("/t/:tenant/session", async (c) => {
  const stub = tenant(c);
  if (stub === undefined) {
    return await c.notFound();
  }

  const request = SessionRequest.safeParse(await c.req.json().catch(() => undefined));
  if (!request.success) {
    return c.body(null, 400);
  }

  const signIn = await stub.signIn(request.data.grant, request.data.verifier, callbackURL(c));
  switch (signIn.outcome) {
    case "signedIn":
      return c.json({ refreshToken: signIn.refreshToken });
    case "unknownTenant":
      return await c.notFound();
    case "refused":
      return c.body(null, 403);
  }
});

export default app;
