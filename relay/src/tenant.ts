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
  // `verify` throws on an empty argument.
  if (delivery.signature === "" || delivery.body === "") return false;
  return verify(secret, delivery.body, delivery.signature);
}

/** One tenant: an account whose owner registered its own GitHub App with the relay. */
export class Tenant extends DurableObject<Env> {
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
    if (!inviteAccepted(this.env.INVITE_CODES, registration.invite)) return "inviteRevoked";

    const action = classifyDelivery(delivery.event, delivery.body);
    if (action.action === "delete") await this.ctx.storage.deleteAll();
    return "accepted";
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
    const access = await accessForRefreshToken(registration, token);
    if (!access) return new Response(null, { status: 401 });

    const session: Session = {
      id: crypto.randomUUID(),
      expiresAt: Math.floor(Date.now() / 1000) + sessionSeconds,
    };
    const { 0: client, 1: server } = new WebSocketPair();
    this.ctx.acceptWebSocket(server);
    server.serializeAttachment(session);
    for (const repository of access.repositories) {
      this.sessionRepositories.exec(
        "INSERT OR IGNORE INTO session_repository (repository, session) VALUES (?, ?)",
        repository.id,
        session.id,
      );
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
    return new Response(null, { status: 101, webSocket: client });
  }

  async alarm(): Promise<void> {
    await this.closeExpiredSessions();
  }

  async webSocketClose(socket: WebSocket): Promise<void> {
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
    if (next !== undefined) await this.ctx.storage.setAlarm(next * 1000);
  }

  /** Deletes the repository IDs kept for a socket's session. */
  private forget(socket: WebSocket): void {
    const session = socket.deserializeAttachment() as Session;
    this.sessionRepositories.exec("DELETE FROM session_repository WHERE session = ?", session.id);
  }

  /** The table of which session can see which repository. Created on use, because deleting a tenant drops it. */
  private get sessionRepositories(): SqlStorage {
    this.ctx.storage.sql.exec(
      `CREATE TABLE IF NOT EXISTS session_repository (
        repository INTEGER NOT NULL,
        session TEXT NOT NULL,
        PRIMARY KEY (repository, session)
      ) WITHOUT ROWID`,
    );
    return this.ctx.storage.sql;
  }

  private registration(): Promise<Registration | undefined> {
    return this.ctx.storage.get<Registration>("registration");
  }
}
