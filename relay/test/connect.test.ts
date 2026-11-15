import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";

const registration = {
  invite: "first-code",
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

let next = 0x2000;
async function registeredTenant(): Promise<string> {
  next += 1;
  const tenant = next.toString(16).padStart(32, "0");
  await exports.default.fetch(`https://relay.test/tenants/${tenant}`, {
    method: "PUT",
    body: JSON.stringify(registration),
  });
  return tenant;
}

type GitHubRepository = { id: number; full_name: string };

const refreshed = {
  access_token: "ghu_access",
  expires_in: 28800,
  refresh_token: "ghr_new",
  refresh_token_expires_in: 15897600,
  token_type: "bearer",
  scope: "",
};

/** Stands in for GitHub: the token endpoint answers `token`, and the repository list is served in `pages`. */
function gitHub(token: unknown, pages: GitHubRepository[][] = []) {
  // Octokit works out a token's expiry from the response's Date header.
  const headers = { date: new Date().toUTCString() };
  return vi.spyOn(globalThis, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    switch (url.pathname) {
      case "/login/oauth/access_token":
        return Response.json(token, { headers });
      case "/user/installations":
        return Response.json({ total_count: 1, installations: [{ id: 99 }] }, { headers });
      case "/user/installations/99/repositories": {
        const page = Number(url.searchParams.get("page") ?? "1");
        return Response.json({ total_count: 0, repositories: pages[page - 1] ?? [] }, { headers });
      }
      default:
        return new Response(`unexpected ${init?.method ?? "GET"} ${url}`, { status: 500 });
    }
  });
}

function connect(tenant: string, headers: Record<string, string>): Promise<Response> {
  return exports.default.fetch(`https://relay.test/t/${tenant}/connect`, { headers });
}

const upgrade = { upgrade: "websocket", authorization: "Bearer ghr_old" };

/** Opens a socket and returns it with its first message. */
async function open(tenant: string): Promise<{ socket: WebSocket; first: unknown }> {
  const response = await connect(tenant, upgrade);
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  const first = new Promise<unknown>((resolve) => {
    socket.addEventListener("message", (event) => resolve(JSON.parse(String(event.data))), {
      once: true,
    });
  });
  socket.accept();
  return { socket, first: await first };
}

function closed(socket: WebSocket): Promise<number> {
  return new Promise((resolve) => {
    socket.addEventListener("close", (event) => resolve(event.code), { once: true });
  });
}

function storedRepositories(tenant: string): Promise<number[]> {
  return runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) =>
    state.storage.sql
      .exec<{ repository: number }>("SELECT repository FROM session_repository ORDER BY repository")
      .toArray()
      .map((row) => row.repository),
  );
}

afterEach(() => {
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe("GET /t/:tenant/connect", () => {
  it("opens a socket and sends the session first", async () => {
    const tenant = await registeredTenant();
    const calls = gitHub(refreshed, [
      [
        { id: 7, full_name: "acme/site" },
        { id: 8, full_name: "acme/api" },
      ],
    ]);
    const before = Math.floor(Date.now() / 1000);

    const { first } = await open(tenant);

    expect(first).toMatchObject({
      type: "session",
      refreshToken: "ghr_new",
      repositories: ["acme/site", "acme/api"],
    });
    const { expiresAt } = first as { expiresAt: number };
    expect(expiresAt).toBeGreaterThanOrEqual(before + 8 * 60 * 60);
    expect(expiresAt).toBeLessThanOrEqual(before + 8 * 60 * 60 + 5);
    expect(await storedRepositories(tenant)).toEqual([7, 8]);

    const refresh = JSON.parse(String(calls.mock.calls[0][1]?.body));
    expect(refresh).toMatchObject({ grant_type: "refresh_token", refresh_token: "ghr_old" });
  });

  it("reads every page of the repository list", async () => {
    const tenant = await registeredTenant();
    const firstPage = Array.from({ length: 100 }, (_, index) => ({
      id: index + 1,
      full_name: `acme/repo-${index + 1}`,
    }));
    gitHub(refreshed, [firstPage, [{ id: 101, full_name: "acme/repo-101" }]]);

    const { first } = await open(tenant);

    expect((first as { repositories: string[] }).repositories).toHaveLength(101);
    expect(await storedRepositories(tenant)).toHaveLength(101);
  });

  it("refuses a refresh token GitHub refuses", async () => {
    const tenant = await registeredTenant();
    gitHub({ error: "bad_refresh_token", error_description: "The refresh token is invalid." });

    expect((await connect(tenant, upgrade)).status).toBe(401);
  });

  it("asks GitHub nothing without a token, an upgrade, or a registered tenant", async () => {
    const tenant = await registeredTenant();
    const calls = gitHub(refreshed);

    expect((await connect(tenant, { upgrade: "websocket" })).status).toBe(401);
    expect((await connect(tenant, { authorization: "Bearer ghr_old" })).status).toBe(426);
    expect((await connect("f".repeat(32), upgrade)).status).toBe(404);
    expect(calls).not.toHaveBeenCalled();
  });

  it("forgets a session's repositories when its socket closes", async () => {
    const tenant = await registeredTenant();
    gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    const { socket } = await open(tenant);

    socket.close(1000, "done");

    await vi.waitFor(async () => expect(await storedRepositories(tenant)).toEqual([]));
  });

  it("closes a socket after eight hours so the client reconnects", async () => {
    const tenant = await registeredTenant();
    gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    const { socket } = await open(tenant);
    const code = closed(socket);

    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 8 * 60 * 60 * 1000 + 1000);
    expect(await runDurableObjectAlarm(env.TENANT.getByName(tenant))).toBe(true);

    expect(await code).toBe(4001);
    expect(await storedRepositories(tenant)).toEqual([]);
  });
});
