/** How long a socket stays open before the client must reconnect and have its access checked again. */
export const sessionSeconds = 8 * 60 * 60;

/** The WebSocket close codes the relay sends. */
export const closeCode = {
  /** Reconnect now: the session ran out, or someone's access changed. */
  recheck: 4001,
} as const;

/** One open socket. `expiresAt` is in Unix seconds. */
export type Session = { id: string; expiresAt: number };

/** The token from an `Authorization: Bearer <token>` header. */
export function bearerToken(header: string | null): string | undefined {
  return /^Bearer (\S+)$/.exec(header ?? "")?.[1];
}

/** Which sessions have run out at `now`, and when the next one will. */
export function expiry(
  sessions: Session[],
  now: number,
): { expired: Session[]; next: number | undefined } {
  const expired = sessions.filter((session) => session.expiresAt <= now);
  const open = sessions.filter((session) => session.expiresAt > now);
  const next = open.length > 0 ? Math.min(...open.map((session) => session.expiresAt)) : undefined;
  return { expired, next };
}
