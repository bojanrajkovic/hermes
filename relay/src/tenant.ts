import { DurableObject } from "cloudflare:workers";
import { verify } from "@octokit/webhooks-methods";
import { classifyDelivery } from "./delivery";
import { accessForRefreshToken, refreshTokenForCode } from "./github";
import {
  decideRegistration,
  inviteAccepted,
  type Registration,
  type RegistrationDecision,
} from "./registration";
import { bearerToken, closeCode, expiry, sessionSeconds, type Session } from "./session";

/** A webhook request as GitHub sent it. */
export type Delivery = {
  /** The `X-GitHub-Event` header. */
  event: string;
  /** The `X-GitHub-Delivery` header. */
  id: string;
  /** The `X-Hub-Signature-256` header. */
  signature: string;
  /** The request body, unparsed, because the signature covers its exact bytes. */
  body: string;
};

export type DeliveryOutcome = "accepted" | "unknownTenant" | "badSignature" | "inviteRevoked";

export type SignIn =
  | { outcome: "signedIn"; refreshToken: string }
  | { outcome: "unknownTenant" }
  | { outcome: "refused" };

/** Whether GitHub signed this delivery with the tenant's webhook secret. */
async function signed(delivery: Delivery, secret: string): Promise<boolean> {
  // `verify` throws on an empty argument, and on a signature that is not `sha256=<hex>`.
  if (delivery.signature === "" || delivery.body === "") return false;
  try {
    return await verify(secret, delivery.body, delivery.signature);
  } catch {
    return false;
  }
}

/** Sends on a socket, and does nothing when it has just closed. */
function send(socket: WebSocket, message: string): void {
  try {
    socket.send(message);
  } catch {
    // The client went away between the lookup and the send. Its close handler cleans up.
  }
}

/** One tenant: an account whose owner registered its own GitHub App with the relay. */
export class Tenant extends DurableObject<Env> {
  /**
   * How many times every socket has been closed. A connect that was waiting on GitHub
   * compares it, to see whether its repository list went out of date meanwhile. A field is
   * enough: a waiting request keeps this object in memory.
   */
  private closures = 0;

  async register(body: unknown): Promise<RegistrationDecision["outcome"]> {
    const existing = await this.registration();
    const decision = decideRegistration(body, this.env.INVITE_CODES, existing);

    if (decision.outcome === "accepted") {
      await this.ctx.storage.put("registration", decision.registration);
    }
    return decision.outcome;
  }

  async deliver(delivery: Delivery): Promise<DeliveryOutcome> {
    const registration = await this.registration();
    if (!registration) return "unknownTenant";

    if (!(await signed(delivery, registration.webhookSecret))) return "badSignature";
    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) {
      this.closeEverySocket(closeCode.tenantGone, "invite withdrawn");
      return "inviteRevoked";
    }

    const action = classifyDelivery(delivery.event, delivery.body);
    switch (action.action) {
      case "forward":
        this.forward(delivery, action.repository);
        break;
      case "recheck":
        this.closeEverySocket(closeCode.recheck, "recheck");
        break;
      case "delete":
        this.closeEverySocket(closeCode.tenantGone, "uninstalled");
        await this.ctx.storage.deleteAll();
        break;
      case "ignore":
        break;
    }
    return "accepted";
  }

  /** Sends a delivery to the sockets whose user can see its repository. */
  private forward(delivery: Delivery, repository: number): void {
    if (!this.hasSessionTable) return;
    const sessions = new Set(
      this.ctx.storage.sql
        .exec<{ session: string }>(
          "SELECT session FROM session_repository WHERE repository = ?",
          repository,
        )
        .toArray()
        .map((row) => row.session),
    );
    if (sessions.size === 0) return;

    // The body goes in as GitHub sent it, so the client gets the payload byte for byte.
    const message =
      `{"type":"event","event":${JSON.stringify(delivery.event)},` +
      `"delivery":${JSON.stringify(delivery.id)},"payload":${delivery.body}}`;

    for (const socket of this.ctx.getWebSockets()) {
      const session = socket.deserializeAttachment() as Session;
      if (sessions.has(session.id)) send(socket, message);
    }
  }

  private closeEverySocket(code: number, reason: string): void {
    this.closures += 1;
    for (const socket of this.ctx.getWebSockets()) {
      this.forget(socket);
      socket.close(code, reason);
    }
  }

  /** The tenant App's client ID, which GitHub's sign-in page needs. */
  async clientID(): Promise<string | undefined> {
    return (await this.registration())?.clientID;
  }

  /** Finishes a browser sign-in: trades GitHub's code for the user's refresh token. */
  async signIn(code: string, redirectURL: string): Promise<SignIn> {
    const registration = await this.registration();
    if (!registration) return { outcome: "unknownTenant" };
    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) return { outcome: "refused" };

    const refreshToken = await refreshTokenForCode(registration, code, redirectURL);
    return refreshToken ? { outcome: "signedIn", refreshToken } : { outcome: "refused" };
  }

  /**
   * Opens a socket for a signed-in user. The request carries the user's refresh token.
   *
   * The relay keeps the IDs of the repositories the user can see, for as long as the socket
   * is open, and sends the replacement refresh token as the socket's first message.
   */
  async fetch(request: Request): Promise<Response> {
    const registration = await this.registration();
    if (!registration || !inviteAccepted(this.env.INVITE_CODES, registration.invite)) {
      return new Response(null, { status: 404 });
    }
    const token = bearerToken(request.headers.get("authorization"));
    if (!token) return new Response(null, { status: 401 });
    const closures = this.closures;
    const access = await accessForRefreshToken(registration, token);
    if (!access) return new Response(null, { status: 401 });

    // Deliveries ran while GitHub answered. One may have deleted the tenant, or closed every
    // socket because someone's access changed, which makes the list just read out of date.
    if (!(await this.registration())) return new Response(null, { status: 404 });
    const outOfDate = closures !== this.closures;

    const session: Session = {
      id: crypto.randomUUID(),
      expiresAt: Math.floor(Date.now() / 1000) + sessionSeconds,
    };
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(session);
    if (!outOfDate) {
      this.createSessionTable();
      for (const repository of access.repositories) {
        this.ctx.storage.sql.exec(
          "INSERT OR IGNORE INTO session_repository (repository, session) VALUES (?, ?)",
          repository.id,
          session.id,
        );
      }
    }
    await this.closeExpiredSessions();

    server.send(
      JSON.stringify({
        type: "session",
        refreshToken: access.refreshToken,
        expiresAt: session.expiresAt,
        repositories: access.repositories.map((repository) => repository.fullName),
      }),
    );
    // The old refresh token is spent, so the client needs the session message either way.
    // With an out-of-date list it then reconnects for a fresh one.
    if (outOfDate) server.close(closeCode.recheck, "recheck");
    return new Response(null, { status: 101, webSocket: client });
  }

  async alarm(): Promise<void> {
    await this.closeExpiredSessions();
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
    this.forget(socket);
  }

  async webSocketError(socket: WebSocket): Promise<void> {
    this.forget(socket);
  }

  /** Closes the sockets whose session ran out, and sets the alarm for the next one that will. */
  private async closeExpiredSessions(): Promise<void> {
    const sockets = this.ctx.getWebSockets();
    const sessions = sockets.map((socket) => socket.deserializeAttachment() as Session);
    const { expired, next } = expiry(sessions, Math.floor(Date.now() / 1000));

    for (const socket of sockets) {
      const session = socket.deserializeAttachment() as Session;
      if (expired.some((other) => other.id === session.id)) {
        this.forget(socket);
        socket.close(closeCode.recheck, "recheck");
      }
    }
    this.forgetSessionsWithoutSocket(sessions.filter((session) => !expired.includes(session)));
    if (next !== undefined) await this.ctx.storage.setAlarm(next * 1000);
  }

  /**
   * Deletes the repository IDs of sessions that have no open socket. A socket that ends when
   * the Durable Object shuts down may never report its close.
   */
  private forgetSessionsWithoutSocket(open: Session[]): void {
    if (!this.hasSessionTable) return;
    const stored = this.ctx.storage.sql
      .exec<{ session: string }>("SELECT DISTINCT session FROM session_repository")
      .toArray();
    for (const { session } of stored) {
      if (!open.some((other) => other.id === session)) {
        this.ctx.storage.sql.exec("DELETE FROM session_repository WHERE session = ?", session);
      }
    }
  }

  /** Deletes the repository IDs kept for a socket's session. */
  private forget(socket: WebSocket): void {
    if (!this.hasSessionTable) return;
    const session = socket.deserializeAttachment() as Session;
    this.ctx.storage.sql.exec("DELETE FROM session_repository WHERE session = ?", session.id);
  }

  /**
   * Creates the table of which session can see which repository. Only a connect creates it,
   * so a deleted tenant, whose sockets report their close afterwards, keeps nothing stored.
   */
  private createSessionTable(): void {
    this.ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS session_repository (
        repository INTEGER NOT NULL,
        session TEXT NOT NULL,
        PRIMARY KEY (repository, session)
      ) WITHOUT ROWID`,
    );
  }

  private get hasSessionTable(): boolean {
    const tables = this.ctx.storage.sql.exec(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'session_repository'",
    );
    return tables.toArray().length > 0;
  }

  private registration(): Promise<Registration | undefined> {
    return this.ctx.storage.get<Registration>("registration");
  }
}
