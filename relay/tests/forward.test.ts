import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { sign } from "@octokit/webhooks-methods";
import { afterEach, assert, describe, expect, it, vi } from "vitest";
import { z } from "zod";

const registration = {
  invite: "first-code",
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

let next = 0x3000;
async function registeredTenant(): Promise<string> {
  next += 1;
  const tenant = next.toString(16).padStart(32, "0");
  await exports.default.fetch(`https://relay.test/tenants/${tenant}`, {
    method: "PUT",
    body: JSON.stringify(registration),
  });

  return tenant;
}

/** Stands in for GitHub: every refresh succeeds, and the user sees the repositories with these IDs. */
function userSees(...repositories: number[]): void {
  const headers = { date: new Date().toUTCString() };
  const answer = (path: string): Response => {
    switch (path) {
      case "/login/oauth/access_token":
        return Response.json(
          {
            access_token: "ghu_access",
            expires_in: 28800,
            refresh_token: "ghr_new",
            refresh_token_expires_in: 15897600,
            token_type: "bearer",
            scope: "",
          },
          { headers },
        );
      case "/user/installations":
        return Response.json({ total_count: 1, installations: [{ id: 99 }] }, { headers });
      default:
        return Response.json(
          {
            total_count: repositories.length,
            repositories: repositories.map((id) => ({ id, full_name: `acme/repo-${String(id)}` })),
          },
          { headers },
        );
    }
  };

  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new URL(input instanceof Request ? input.url : String(input));

    return await Promise.resolve(answer(url.pathname));
  });
}

/** GitHub's held-back repository list: `release` lets it go, and `asked` says whether the relay asked for it. */
type HeldAnswer = { release: () => void; asked: () => boolean };

/** Like `userSees`, but GitHub holds back the repository list until `release` is called. */
function userSeesAfterAWait(...repositories: number[]): HeldAnswer {
  const held = Promise.withResolvers<undefined>();
  let asked = false;
  userSees(...repositories);
  const answer = vi.mocked(globalThis.fetch).getMockImplementation();
  assert(answer !== undefined, "userSees set no answer");
  vi.mocked(globalThis.fetch).mockImplementation(async (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    if (url.pathname.endsWith("/repositories")) {
      asked = true;
      await held.promise;
    }

    return await answer(input, init);
  });

  return {
    release: () => {
      held.resolve(undefined);
    },
    asked: () => asked,
  };
}

/** The part of a forwarded pull request event the tests read. */
const PullRequestEvent = z.object({ payload: z.object({ number: z.number() }) });

/** The pull request number in a forwarded event. */
function pullRequestNumber(event: string): number {
  return PullRequestEvent.parse(JSON.parse(event)).payload.number;
}

/** A socket that has said hello, and what has arrived on it so far. */
type HelloSocket = {
  /** Whether the session message has arrived. */
  hasSession: () => boolean;
  /** The messages after the session message. */
  events: () => string[];
  closeCode: () => number | undefined;
};

/** A socket that has said hello. Its messages and close code can be awaited in order. */
async function hello(tenant: string): Promise<HelloSocket> {
  const response = await exports.default.fetch(`https://relay.test/t/${tenant}/connect`, {
    headers: { upgrade: "websocket" },
  });
  const socket = response.webSocket;
  assert(socket !== null, "the relay opened no socket");
  const messages: string[] = [];
  let closeCode: number | undefined = undefined;
  socket.addEventListener("message", (event) => messages.push(String(event.data)));
  socket.addEventListener("close", (event) => (closeCode = event.code));
  socket.accept();
  socket.send(JSON.stringify({ type: "hello", refreshToken: "ghr_old" }));

  return {
    hasSession: () => messages.length > 0,
    events: () => messages.slice(1),
    closeCode: () => closeCode,
  };
}

/** A socket that has its session. */
async function open(tenant: string): Promise<HelloSocket> {
  const socket = await hello(tenant);
  await vi.waitFor(() => {
    expect(socket.hasSession()).toBe(true);
  });

  return socket;
}

async function deliver(tenant: string, event: string, body: string): Promise<number> {
  const response = await exports.default.fetch(`https://relay.test/hook/${tenant}`, {
    method: "POST",
    headers: {
      "x-github-event": event,
      "x-github-delivery": "delivery-1",
      "x-hub-signature-256": await sign(registration.webhookSecret, body),
    },
    body,
  });

  return response.status;
}

async function storedSessions(tenant: string): Promise<number> {
  return await runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) => {
    const { sql } = state.storage;
    const created = sql.exec("SELECT 1 FROM sqlite_master WHERE name = 'session_repository'");
    if (created.toArray().length === 0) {
      return 0;
    }

    return sql.exec("SELECT DISTINCT session FROM session_repository").toArray().length;
  });
}

afterEach(() => vi.restoreAllMocks());

describe("forwarding a delivery", () => {
  it("sends the payload as GitHub sent it, with the event's name and delivery ID", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);
    // Odd spacing and an escape: a relay that re-encoded the payload would change these bytes.
    const body = '{ "action":"opened",  "repository": {"id": 7}, "title": "caf\\u00e9" }';

    expect(await deliver(tenant, "pull_request", body)).toBe(202);

    await vi.waitFor(() => {
      expect(socket.events()).toHaveLength(1);
    });
    expect(socket.events()[0]).toBe(
      `{"type":"event","event":"pull_request","delivery":"delivery-1","payload":${body}}`,
    );
  });

  it("sends a delivery only to the users who can see its repository", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const seesSeven = await open(tenant);
    userSees(8);
    const seesEight = await open(tenant);

    await deliver(tenant, "pull_request", '{"repository":{"id":8},"number":1}');
    await deliver(tenant, "pull_request", '{"repository":{"id":9},"number":2}');
    await deliver(tenant, "pull_request", '{"repository":{"id":7},"number":3}');

    await vi.waitFor(() => {
      expect(seesSeven.events()).toHaveLength(1);
    });
    expect(seesSeven.events().map((event) => pullRequestNumber(event))).toEqual([3]);
    expect(seesEight.events().map((event) => pullRequestNumber(event))).toEqual([1]);
  });
});

describe("a change in who can see what", () => {
  it("closes every socket so each client reconnects and is checked again", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);

    await deliver(tenant, "member", '{"action":"removed","repository":{"id":7}}');

    await vi.waitFor(() => {
      expect(socket.closeCode()).toBe(4001);
    });
    expect(socket.events()).toEqual([]);
    expect(await storedSessions(tenant)).toBe(0);
  });
});

describe("a delivery that arrives while GitHub is answering for a socket", () => {
  it("gives the client its new token, then has it reconnect, when access changed", async () => {
    const tenant = await registeredTenant();
    const gitHub = userSeesAfterAWait(7);
    const socket = await hello(tenant);
    await vi.waitFor(() => {
      expect(gitHub.asked()).toBe(true);
    });

    await deliver(tenant, "member", '{"action":"removed","repository":{"id":7}}');
    expect(socket.closeCode()).toBeUndefined();
    gitHub.release();

    await vi.waitFor(() => {
      expect(socket.closeCode()).toBe(4001);
    });
    expect(socket.hasSession()).toBe(true);
    expect(await storedSessions(tenant)).toBe(0);
  });

  it("tells the client to stop, with no session, when the App was uninstalled", async () => {
    const tenant = await registeredTenant();
    const gitHub = userSeesAfterAWait(7);
    const socket = await hello(tenant);
    await vi.waitFor(() => {
      expect(gitHub.asked()).toBe(true);
    });

    await deliver(tenant, "installation", '{"action":"deleted"}');
    gitHub.release();

    await vi.waitFor(() => {
      expect(socket.closeCode()).toBe(4004);
    });
    expect(socket.hasSession()).toBe(false);
  });
});

describe("a tenant that ends", () => {
  it("tells clients to stop when the App is uninstalled", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);

    await deliver(tenant, "installation", '{"action":"deleted"}');

    await vi.waitFor(() => {
      expect(socket.closeCode()).toBe(4004);
    });
    // The client's close reaches the relay after the tenant is deleted, and must leave nothing.
    const left = await runInDurableObject(
      env.TENANT.getByName(tenant),
      async (_instance, state) => ({
        keys: (await state.storage.list()).size,
        tables: state.storage.sql
          .exec("SELECT name FROM sqlite_master WHERE name = 'session_repository'")
          .toArray().length,
      }),
    );
    expect(left).toEqual({ keys: 0, tables: 0 });
  });

  it("tells clients to stop when the invite code is withdrawn", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);
    await runInDurableObject(env.TENANT.getByName(tenant), async (_instance, state) => {
      await state.storage.put("registration", { ...registration, invite: "withdrawn-code" });
    });

    expect(await deliver(tenant, "pull_request", '{"repository":{"id":7}}')).toBe(403);

    await vi.waitFor(() => {
      expect(socket.closeCode()).toBe(4004);
    });
    expect(socket.events()).toEqual([]);
  });
});
