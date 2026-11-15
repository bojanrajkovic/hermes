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

    const response = await get(`/t/${tenant}/login?state=abc`);

    expect(response.status).toBe(302);
    const location = new URL(response.headers.get("location") ?? "");
    expect(location.origin + location.pathname).toBe("https://github.com/login/oauth/authorize");
    expect(location.searchParams.get("client_id")).toBe("Iv1.client");
    expect(location.searchParams.get("redirect_uri")).toBe(`https://relay.test/t/${tenant}/callback`);
    expect(location.searchParams.get("state")).toBe("abc");
  });

  it("does not know an unregistered tenant", async () => {
    expect((await get(`/t/${unregistered}/login?state=abc`)).status).toBe(404);
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

    const response = await requestSession(tenant, { grant: "gh-code" });

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ refreshToken: "ghr_refresh" });
    const [url, init] = gitHub.mock.calls[0];
    expect(String(url)).toBe("https://github.com/login/oauth/access_token");
    expect(JSON.parse(String(init?.body))).toEqual({
      client_id: "Iv1.client",
      client_secret: "client-secret",
      code: "gh-code",
      redirect_uri: `https://relay.test/t/${tenant}/callback`,
    });
  });

  it("refuses a grant GitHub refuses", async () => {
    const tenant = await registeredTenant();
    gitHubAnswers({
      error: "bad_verification_code",
      error_description: "The code passed is incorrect or expired.",
    });

    expect((await requestSession(tenant, { grant: "stale" })).status).toBe(403);
  });

  it("refuses when the App's user tokens don't expire, so there is no refresh token", async () => {
    const tenant = await registeredTenant();
    gitHubAnswers({ access_token: "ghu_access", token_type: "bearer", scope: "" });

    expect((await requestSession(tenant, { grant: "gh-code" })).status).toBe(403);
  });

  it("does not ask GitHub about an unregistered tenant or a missing grant", async () => {
    const gitHub = gitHubAnswers({});

    expect((await requestSession(unregistered, { grant: "gh-code" })).status).toBe(404);
    expect((await requestSession(await registeredTenant(), {})).status).toBe(400);
    expect(gitHub).not.toHaveBeenCalled();
  });
});
