import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { sign } from "@octokit/webhooks-methods";
import { afterEach, describe, expect, it, vi } from "vitest";

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
function userSees(...repositories: number[]) {
  const headers = { date: new Date().toUTCString() };
  vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    switch (url.pathname) {
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
            repositories: repositories.map((id) => ({ id, full_name: `acme/repo-${id}` })),
          },
          { headers },
        );
    }
  });
}

/** An open socket whose messages and close code can be awaited in order. */
async function open(tenant: string) {
  const response = await exports.default.fetch(`https://relay.test/t/${tenant}/connect`, {
    headers: { upgrade: "websocket", authorization: "Bearer ghr_old" },
  });
  const socket = response.webSocket!;
  const messages: string[] = [];
  let closeCode: number | undefined;
  socket.addEventListener("message", (event) => messages.push(String(event.data)));
  socket.addEventListener("close", (event) => (closeCode = event.code));
  socket.accept();
  await vi.waitFor(() => expect(messages).toHaveLength(1)); // the session message

  return {
    /** The messages after the session message. */
    events: () => messages.slice(1),
    closeCode: () => closeCode,
  };
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

function storedSessions(tenant: string): Promise<number> {
  return runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) =>
    state.storage.sql.exec("SELECT DISTINCT session FROM session_repository").toArray().length,
  );
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

    await vi.waitFor(() => expect(socket.events()).toHaveLength(1));
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

    await vi.waitFor(() => expect(seesSeven.events()).toHaveLength(1));
    expect(JSON.parse(seesSeven.events()[0]).payload.number).toBe(3);
    expect(seesEight.events().map((event) => JSON.parse(event).payload.number)).toEqual([1]);
  });
});

describe("a change in who can see what", () => {
  it("closes every socket so each client reconnects and is checked again", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);

    await deliver(tenant, "member", '{"action":"removed","repository":{"id":7}}');

    await vi.waitFor(() => expect(socket.closeCode()).toBe(4001));
    expect(socket.events()).toEqual([]);
    expect(await storedSessions(tenant)).toBe(0);
  });
});

describe("a tenant that ends", () => {
  it("tells clients to stop when the App is uninstalled", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);

    await deliver(tenant, "installation", '{"action":"deleted"}');

    await vi.waitFor(() => expect(socket.closeCode()).toBe(4004));
  });

  it("tells clients to stop when the invite code is withdrawn", async () => {
    const tenant = await registeredTenant();
    userSees(7);
    const socket = await open(tenant);
    await runInDurableObject(env.TENANT.getByName(tenant), (_instance, state) =>
      state.storage.put("registration", { ...registration, invite: "withdrawn-code" }),
    );

    expect(await deliver(tenant, "pull_request", '{"repository":{"id":7}}')).toBe(403);

    await vi.waitFor(() => expect(socket.closeCode()).toBe(4004));
    expect(socket.events()).toEqual([]);
  });
});
