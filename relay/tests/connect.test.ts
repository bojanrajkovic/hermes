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

function connect(tenant: string, headers: Record<string, string> = { upgrade: "websocket" }) {
  return exports.default.fetch(`https://relay.test/t/${tenant}/connect`, { headers });
}

/** Opens a socket and records what arrives on it. Says nothing yet. */
async function socketTo(tenant: string) {
  const response = await connect(tenant);
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  const messages: unknown[] = [];
  let closeCode: number | undefined;
  socket.addEventListener("message", (event) => messages.push(JSON.parse(String(event.data))));
  socket.addEventListener("close", (event) => (closeCode = event.code));
  socket.accept();
  return { socket, messages, closeCode: () => closeCode };
}

const hello = JSON.stringify({ type: "hello", refreshToken: "ghr_old" });

/** Opens a socket, says hello, and waits for the session message. */
async function open(tenant: string) {
  const opened = await socketTo(tenant);
  opened.socket.send(hello);
  await vi.waitFor(() => expect(opened.messages).toHaveLength(1));
  return { ...opened, first: opened.messages[0] };
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
  it("opens a socket with no token in the request, and asks GitHub nothing yet", async () => {
    const tenant = await registeredTenant();
    const calls = gitHub(refreshed);

    const { messages } = await socketTo(tenant);

    expect(messages).toEqual([]);
    expect(calls).not.toHaveBeenCalled();
  });

  it("answers 426 to a plain request and 404 for an unregistered tenant", async () => {
    const tenant = await registeredTenant();

    expect((await connect(tenant, {})).status).toBe(426);
    expect((await connect("f".repeat(32))).status).toBe(404);
  });
});

describe("a socket's first message", () => {
  it("is answered with the session, built from the refresh token it carries", async () => {
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

    const refresh = JSON.parse(String(calls.mock.calls[0]?.[1]?.body));
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

  it("closes with 4003 when GitHub refuses the refresh token", async () => {
    const tenant = await registeredTenant();
    gitHub({ error: "bad_refresh_token", error_description: "The refresh token is invalid." });
    const opened = await socketTo(tenant);

    opened.socket.send(hello);

    await vi.waitFor(() => expect(opened.closeCode()).toBe(4003));
    expect(opened.messages).toEqual([]);
  });

  it("closes with 1011 when GitHub is down, so the client keeps its token", async () => {
    const tenant = await registeredTenant();
    vi.spyOn(globalThis, "fetch").mockImplementation(
      async () => new Response("unavailable", { status: 503 }),
    );
    const opened = await socketTo(tenant);

    opened.socket.send(hello);

    await vi.waitFor(() => expect(opened.closeCode()).toBe(1011));
  });

  it("closes with 4003, and asks GitHub nothing, when it is not a hello", async () => {
    const tenant = await registeredTenant();
    const calls = gitHub(refreshed);
    const opened = await socketTo(tenant);

    opened.socket.send(JSON.stringify({ type: "subscribe" }));

    await vi.waitFor(() => expect(opened.closeCode()).toBe(4003));
    expect(calls).not.toHaveBeenCalled();
  });

  it("is the only one read: a second hello starts nothing", async () => {
    const tenant = await registeredTenant();
    const calls = gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    const { socket, messages } = await open(tenant);
    const asked = calls.mock.calls.length;

    socket.send(hello);
    await new Promise((resolve) => setTimeout(resolve, 50));

    expect(calls.mock.calls).toHaveLength(asked);
    expect(messages).toHaveLength(1);
  });
});

describe("a socket's lifetime", () => {
  it("ends after a minute when the client never says hello", async () => {
    const tenant = await registeredTenant();
    const opened = await socketTo(tenant);

    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 61 * 1000);
    expect(await runDurableObjectAlarm(env.TENANT.getByName(tenant))).toBe(true);

    await vi.waitFor(() => expect(opened.closeCode()).toBe(4003));
  });

  it("forgets a session's repositories when its socket closes", async () => {
    const tenant = await registeredTenant();
    gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    const { socket } = await open(tenant);

    socket.close(1000, "done");

    await vi.waitFor(async () => expect(await storedRepositories(tenant)).toEqual([]));
  });

  it("deletes the repositories of a session whose socket is gone", async () => {
    const tenant = await registeredTenant();
    gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    await open(tenant);
    const stub = env.TENANT.getByName(tenant);
    await runInDurableObject(stub, (_instance, state) => {
      state.storage.sql.exec(
        "INSERT INTO session_repository (repository, session) VALUES (9, 'left-behind')",
      );
    });

    await runDurableObjectAlarm(stub);

    expect(await storedRepositories(tenant)).toEqual([7]);
  });

  it("ends after eight hours so the client reconnects", async () => {
    const tenant = await registeredTenant();
    gitHub(refreshed, [[{ id: 7, full_name: "acme/site" }]]);
    const opened = await open(tenant);
    const stub = env.TENANT.getByName(tenant);
    const { expiresAt } = opened.first as { expiresAt: number };

    // The alarm is set for the moment the session runs out, and running it early closes nothing.
    const alarm = () => runInDurableObject(stub, (_instance, state) => state.storage.getAlarm());
    expect(await alarm()).toBe(expiresAt * 1000);
    await runDurableObjectAlarm(stub);
    expect(await storedRepositories(tenant)).toEqual([7]);
    expect(await alarm()).toBe(expiresAt * 1000);

    vi.useFakeTimers({ toFake: ["Date"] });
    vi.setSystemTime(Date.now() + 8 * 60 * 60 * 1000 + 1000);
    expect(await runDurableObjectAlarm(stub)).toBe(true);

    await vi.waitFor(() => expect(opened.closeCode()).toBe(4001));
    expect(await storedRepositories(tenant)).toEqual([]);
  });
});
