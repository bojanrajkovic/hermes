import { z } from "zod";
import { parseJSON } from "./json";

/** How long a socket stays open before the client must reconnect and have its access checked again. */
export const sessionSeconds = 8 * 60 * 60;

/** How long a new socket may stay silent before the relay closes it. */
export const helloSeconds = 60;

/** How long the relay waits on GitHub for one socket before giving up on it. */
export const authorizingSeconds = 5 * 60;

/** The WebSocket close codes the relay sends. */
export const closeCode = {
  /** GitHub could not be reached. The client's refresh token was not used. */
  unreachable: 1011,
  /** Reconnect now: the session ran out, or someone's access changed. */
  recheck: 4001,
  /** Sign in again: GitHub refused the refresh token, or the client sent none. */
  notAuthorized: 4003,
  /** Stop: the tenant's App was uninstalled. */
  tenantGone: 4004,
} as const;

/**
 * One socket. `expiresAt` is in Unix seconds.
 *
 * A socket starts `awaitingHello`. Its first message moves it to `authorizing`, while the
 * relay asks GitHub what its user can see, and then to `open`, when it gets deliveries.
 */
export type Session = {
  id: string;
  expiresAt: number;
  state: "awaitingHello" | "authorizing" | "open";
};

/** A GitHub login. It goes into the path of a request to GitHub, so nothing else gets through. */
const Login = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9\-]{0,38}$/v);

const HelloMessage = z.object({
  type: z.literal("hello"),
  refreshToken: z.string().min(1),
  organization: Login.optional(),
});

/**
 * What a socket's first message carries: the user's refresh token, and the organization the
 * client says the tenant belongs to, when it knows one.
 */
export type Hello = { refreshToken: string; organization: string | undefined };

/**
 * Reads a socket's first message, `{"type":"hello","refreshToken":"…","organization":"acme"}`.
 *
 * The token travels in a message, not a header, because Cloudflare can show a Worker's
 * operator the headers of a request and never the contents of a socket.
 *
 * The relay does not trust `organization` and does not store it. It only names the
 * organization in one question to GitHub: see `accessForRefreshToken`.
 */
export function hello(message: string | ArrayBuffer): Hello | undefined {
  if (typeof message !== "string") {
    return undefined;
  }

  const parsed = HelloMessage.safeParse(parseJSON(message));
  if (!parsed.success) {
    return undefined;
  }

  return { refreshToken: parsed.data.refreshToken, organization: parsed.data.organization };
}

/** The sessions that have run out, and when the next one will, in Unix seconds. */
export type Expiry = { expired: Session[]; next: number | undefined };

/** Which sessions have run out at `now`, and when the next one will. */
export function expiry(sessions: Session[], now: number): Expiry {
  const expired = sessions.filter((session) => session.expiresAt <= now);
  const open = sessions.filter((session) => session.expiresAt > now);
  const next = open.length > 0 ? Math.min(...open.map((session) => session.expiresAt)) : undefined;

  return { expired, next };
}

/** The code to close a session that ran out with: an open one reconnects, the others never signed in. */
export function expiredCloseCode(session: Session): number {
  return session.state === "open" ? closeCode.recheck : closeCode.notAuthorized;
}

/** A PKCE code challenge: the base64url SHA-256 of a verifier, 43 characters. */
export const CodeChallenge = z.string().regex(/^[A-Za-z0-9_\-]{43}$/v);

/** A PKCE code verifier, as RFC 7636 defines it. */
export const CodeVerifier = z.string().regex(/^[A-Za-z0-9._~\-]{43,128}$/v);
