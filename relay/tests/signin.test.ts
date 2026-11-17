import { exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";

const registration = {
  invite: "first-code",
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

let next = 0x1000;
async function registeredTenant(): Promise<string> {
  next += 1;
  const tenant = next.toString(16).padStart(32, "0");
  await exports.default.fetch(`https://relay.test/tenants/${tenant}`, {
    method: "PUT",
    body: JSON.stringify(registration),
  });
  return tenant;
}

const unregistered = "f".repeat(32);

function get(path: string): Promise<Response> {
  return exports.default.fetch(`https://relay.test${path}`, { redirect: "manual" });
}

// The example in RFC 7636, appendix B.
const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

function requestSession(tenant: string, body: unknown): Promise<Response> {
  return exports.default.fetch(`https://relay.test/t/${tenant}/session`, {
    method: "POST",
    body: JSON.stringify(body),
  });
}

/** Answers GitHub's token endpoint with `answer`, and records what the relay sent it. */
function gitHubAnswers(answer: unknown) {
  // Octokit works out a token's expiry from the response's Date header.
  const headers = { date: new Date().toUTCString() };
  return vi
    .spyOn(globalThis, "fetch")
    .mockImplementation(async () => Response.json(answer, { headers }));
}

afterEach(() => vi.restoreAllMocks());

describe("GET /t/:tenant/login", () => {
  it("sends the browser to GitHub's sign-in page for the tenant's App", async () => {
    const tenant = await registeredTenant();

    const response = await get(`/t/${tenant}/login?state=abc&code_challenge=${challenge}`);

    expect(response.status).toBe(302);
    const location = new URL(response.headers.get("location") ?? "");
    expect(location.origin + location.pathname).toBe("https://github.com/login/oauth/authorize");
    expect(location.searchParams.get("client_id")).toBe("Iv1.client");
    expect(location.searchParams.get("redirect_uri")).toBe(
      `https://relay.test/t/${tenant}/callback`,
    );
    expect(location.searchParams.get("state")).toBe("abc");
    expect(location.searchParams.get("code_challenge")).toBe(challenge);
    expect(location.searchParams.get("code_challenge_method")).toBe("S256");
  });

  it("refuses a sign-in with no code challenge, or a malformed one", async () => {
    const tenant = await registeredTenant();

    expect((await get(`/t/${tenant}/login?state=abc`)).status).toBe(400);
    expect((await get(`/t/${tenant}/login?state=abc&code_challenge=short`)).status).toBe(400);
  });

  it("does not know an unregistered tenant", async () => {
    expect(
      (await get(`/t/${unregistered}/login?state=abc&code_challenge=${challenge}`)).status,
    ).toBe(404);
  });
});

describe("GET /t/:tenant/callback", () => {
  it("hands GitHub's code to Hermes as the grant", async () => {
    const response = await get(`/t/${unregistered}/callback?code=gh-code&state=abc`);

    expect(response.status).toBe(302);
    expect(response.headers.get("location")).toBe(
      `hermes://relay.session?tenant=${unregistered}&grant=gh-code&state=abc`,
    );
  });

  it("stops when GitHub sent no code", async () => {
    const response = await get(`/t/${unregistered}/callback?error=access_denied&state=abc`);

    expect(response.status).toBe(400);
  });
});

describe("POST /t/:tenant/session", () => {
  it("returns the refresh token GitHub issues for the grant", async () => {
    const tenant = await registeredTenant();
    const gitHub = gitHubAnswers({
      access_token: "ghu_access",
      expires_in: 28800,
      refresh_token: "ghr_refresh",
      refresh_token_expires_in: 15897600,
      token_type: "bearer",
      scope: "",
    });

    const response = await requestSession(tenant, { grant: "gh-code", verifier });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ refreshToken: "ghr_refresh" });
    const [url, init] = gitHub.mock.calls[0] ?? [];
    expect(String(url)).toBe("https://github.com/login/oauth/access_token");
    expect(JSON.parse(String(init?.body))).toEqual({
      client_id: "Iv1.client",
      client_secret: "client-secret",
      code: "gh-code",
      redirect_uri: `https://relay.test/t/${tenant}/callback`,
      code_verifier: verifier,
    });
  });

  it("refuses a grant GitHub refuses", async () => {
    const tenant = await registeredTenant();
    gitHubAnswers({
      error: "bad_verification_code",
      error_description: "The code passed is incorrect or expired.",
    });

    expect((await requestSession(tenant, { grant: "stale", verifier })).status).toBe(403);
  });

  it("refuses when the App's user tokens don't expire, so there is no refresh token", async () => {
    const tenant = await registeredTenant();
    gitHubAnswers({ access_token: "ghu_access", token_type: "bearer", scope: "" });

    expect((await requestSession(tenant, { grant: "gh-code", verifier })).status).toBe(403);
  });

  it("reports an error, not a refusal, when GitHub is down", async () => {
    const tenant = await registeredTenant();
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response("unavailable", { status: 503 }),
    );

    expect((await requestSession(tenant, { grant: "gh-code", verifier })).status).toBe(500);
  });

  it("does not ask GitHub about an unregistered tenant, a missing grant, or a missing verifier", async () => {
    const gitHub = gitHubAnswers({});

    expect((await requestSession(unregistered, { grant: "gh-code", verifier })).status).toBe(404);
    expect((await requestSession(await registeredTenant(), { verifier })).status).toBe(400);
    expect((await requestSession(await registeredTenant(), { grant: "gh-code" })).status).toBe(400);
    expect(gitHub).not.toHaveBeenCalled();
  });
});
