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
import {
  authorizingSeconds,
  closeCode,
  expiredCloseCode,
  expiry,
  helloSeconds,
  helloToken,
  sessionSeconds,
  type Session,
} from "./session";

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
  if (delivery.signature === "" || delivery.body === "") {
    return false;
  }

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

function now(): number {
  return Math.floor(Date.now() / 1000);
}

/** The session a socket carries. */
function sessionOf(socket: WebSocket): Session {
  // oxlint-disable-next-line typescript/no-unsafe-type-assertion -- the relay attaches a Session to every socket it accepts, and nothing else writes the attachment
  return socket.deserializeAttachment() as Session;
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
    if (registration === undefined) {
      return "unknownTenant";
    }

    if (!(await signed(delivery, registration.webhookSecret))) {
      return "badSignature";
    }

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
    if (!this.hasSessionTable) {
      return;
    }

    const sessions = new Set(
      this.ctx.storage.sql
        .exec<{ session: string }>(
          "SELECT session FROM session_repository WHERE repository = ?",
          repository,
        )
        .toArray()
        .map((row) => row.session),
    );
    if (sessions.size === 0) {
      return;
    }

    // The body goes in as GitHub sent it, so the client gets the payload byte for byte.
    const message =
      `{"type":"event","event":${JSON.stringify(delivery.event)},` +
      `"delivery":${JSON.stringify(delivery.id)},"payload":${delivery.body}}`;

    for (const socket of this.ctx.getWebSockets()) {
      const session = sessionOf(socket);
      if (sessions.has(session.id)) {
        send(socket, message);
      }
    }
  }

  /**
   * Closes the sockets a delivery affects. A socket waiting on GitHub is left alone: its
   * refresh token is spent, so it must get its session message, and `closures` tells it
   * what happened meanwhile. A socket that has not said hello has no repository list to go
   * out of date, so only the end of the tenant closes it.
   */
  private closeEverySocket(code: number, reason: string): void {
    this.closures += 1;
    for (const socket of this.ctx.getWebSockets()) {
      const { state } = sessionOf(socket);
      if (state === "authorizing") {
        continue;
      }

      if (state === "awaitingHello" && code === closeCode.recheck) {
        continue;
      }

      this.end(socket, code, reason);
    }
  }

  /** Forgets a socket's session and closes it. */
  private end(socket: WebSocket, code: number, reason: string): void {
    this.forget(socket);
    try {
      socket.close(code, reason);
    } catch {
      // The client closed first.
    }
  }

  /** The tenant App's client ID, which GitHub's sign-in page needs. */
  async clientID(): Promise<string | undefined> {
    return (await this.registration())?.clientID;
  }

  /** Finishes a browser sign-in: trades GitHub's code for the user's refresh token. */
  async signIn(code: string, verifier: string, redirectURL: string): Promise<SignIn> {
    const registration = await this.registration();
    if (registration === undefined) {
      return { outcome: "unknownTenant" };
    }

    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) {
      return { outcome: "refused" };
    }

    const refreshToken = await refreshTokenForCode(registration, code, verifier, redirectURL);

    return refreshToken === undefined || refreshToken === ""
      ? { outcome: "refused" }
      : { outcome: "signedIn", refreshToken };
  }

  /**
   * Opens a socket. The client says who it is in its first message, not in this request,
   * so its refresh token is never in a header.
   */
  override async fetch(_request: Request): Promise<Response> {
    const registration = await this.registration();
    if (registration === undefined || !inviteAccepted(this.env.INVITE_CODES, registration.invite)) {
      return new Response(null, { status: 404 });
    }

    const session: Session = {
      id: crypto.randomUUID(),
      expiresAt: now() + helloSeconds,
      state: "awaitingHello",
    };
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(session);
    await this.closeExpiredSessions();

    return new Response(null, { status: 101, webSocket: client });
  }

  /**
   * Takes a socket's first message, which carries the user's refresh token.
   *
   * The relay uses the token, keeps the IDs of the repositories the user can see for as long
   * as the socket is open, and sends the replacement token back as the session message.
   */
  override async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const session = sessionOf(socket);
    // A client sends one message. Anything after it is ignored.
    if (session.state !== "awaitingHello") {
      return;
    }

    const token = helloToken(message);
    if (token === undefined) {
      this.end(socket, closeCode.notAuthorized, "no hello");

      return;
    }

    const registration = await this.registration();
    if (registration === undefined) {
      this.end(socket, closeCode.tenantGone, "uninstalled");

      return;
    }

    socket.serializeAttachment({
      ...session,
      state: "authorizing",
      expiresAt: now() + authorizingSeconds,
    } satisfies Session);
    const { closures } = this;

    const access = await accessForRefreshToken(registration, token).catch(
      () => "unreachable" as const,
    );
    if (access === "unreachable") {
      this.end(socket, closeCode.unreachable, "GitHub unreachable");

      return;
    }

    if (access === undefined) {
      this.end(socket, closeCode.notAuthorized, "token refused");

      return;
    }

    // Deliveries ran while GitHub answered. One may have deleted the tenant, or closed every
    // open socket because someone's access changed, which makes the list just read out of date.
    if ((await this.registration()) === undefined) {
      this.end(socket, closeCode.tenantGone, "uninstalled");

      return;
    }

    const outOfDate = closures !== this.closures;

    const open: Session = { id: session.id, expiresAt: now() + sessionSeconds, state: "open" };
    socket.serializeAttachment(open);
    if (!outOfDate) {
      this.createSessionTable();
      for (const repository of access.repositories) {
        this.ctx.storage.sql.exec(
          "INSERT OR IGNORE INTO session_repository (repository, session) VALUES (?, ?)",
          repository.id,
          open.id,
        );
      }
    }

    await this.closeExpiredSessions();

    send(
      socket,
      JSON.stringify({
        type: "session",
        refreshToken: access.refreshToken,
        expiresAt: open.expiresAt,
        repositories: access.repositories.map((repository) => repository.fullName),
      }),
    );
    // The old refresh token is spent, so the client needs the session message either way.
    // With an out-of-date list it then reconnects for a fresh one.
    if (outOfDate) {
      this.end(socket, closeCode.recheck, "recheck");
    }
  }

  override async alarm(): Promise<void> {
    await this.closeExpiredSessions();
  }

  override webSocketClose(socket: WebSocket): void {
    this.forget(socket);
  }

  override webSocketError(socket: WebSocket): void {
    this.forget(socket);
  }

  /** Closes the sockets whose session ran out, and sets the alarm for the next one that will. */
  private async closeExpiredSessions(): Promise<void> {
    const sockets = this.ctx.getWebSockets();
    const sessions = sockets.map((socket) => sessionOf(socket));
    const { expired, next } = expiry(sessions, now());

    for (const socket of sockets) {
      const session = sessionOf(socket);
      if (expired.some((other) => other.id === session.id)) {
        this.end(socket, expiredCloseCode(session), "expired");
      }
    }

    this.forgetSessionsWithoutSocket(sessions.filter((session) => !expired.includes(session)));
    if (next !== undefined) {
      await this.ctx.storage.setAlarm(next * 1000);
    }
  }

  /**
   * Deletes the repository IDs of sessions that have no open socket. A socket that ends when
   * the Durable Object shuts down may never report its close.
   */
  private forgetSessionsWithoutSocket(open: Session[]): void {
    if (!this.hasSessionTable) {
      return;
    }

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
    if (!this.hasSessionTable) {
      return;
    }

    const session = sessionOf(socket);
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

  private async registration(): Promise<Registration | undefined> {
    return await this.ctx.storage.get<Registration>("registration");
  }
}
