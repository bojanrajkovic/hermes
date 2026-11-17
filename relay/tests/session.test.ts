import { describe, expect, it } from "vitest";
import {
  CodeChallenge,
  CodeVerifier,
  expiredCloseCode,
  expiry,
  helloToken,
  type Session,
} from "../src/session";

describe("helloToken", () => {
  it("reads the refresh token from a hello", () => {
    expect(helloToken('{"type":"hello","refreshToken":"ghr_abc"}')).toBe("ghr_abc");
  });

  it.each([
    ["not JSON", "hello"],
    ["another type", '{"type":"ping","refreshToken":"ghr_abc"}'],
    ["no token", '{"type":"hello"}'],
    ["an empty token", '{"type":"hello","refreshToken":""}'],
    ["a token that is not text", '{"type":"hello","refreshToken":7}'],
    ["null", "null"],
  ])("finds none in %s", (_name, message) => {
    expect(helloToken(message)).toBeUndefined();
  });

  it("finds none in a binary message", () => {
    expect(helloToken(new ArrayBuffer(8))).toBeUndefined();
  });
});

describe("expiry", () => {
  const early: Session = { id: "early", expiresAt: 100, state: "open" };
  const late: Session = { id: "late", expiresAt: 200, state: "open" };

  it("expires nothing before the first session runs out", () => {
    expect(expiry([late, early], 99)).toEqual({ expired: [], next: 100 });
  });

  it("expires a session at the second it runs out", () => {
    expect(expiry([late, early], 100)).toEqual({ expired: [early], next: 200 });
  });

  it("has no next time once every session has run out", () => {
    expect(expiry([late, early], 500)).toEqual({ expired: [late, early], next: undefined });
    expect(expiry([], 500)).toEqual({ expired: [], next: undefined });
  });
});

describe("expiredCloseCode", () => {
  it("tells an open socket to reconnect", () => {
    expect(expiredCloseCode({ id: "a", expiresAt: 1, state: "open" })).toBe(4001);
  });

  it.each(["awaitingHello", "authorizing"] as const)(
    "tells a socket still %s to sign in",
    (state) => {
      expect(expiredCloseCode({ id: "a", expiresAt: 1, state })).toBe(4003);
    },
  );
});

describe("PKCE values", () => {
  // The example in RFC 7636, appendix B.
  const verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
  const challenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM";

  it("accepts the RFC's verifier and challenge", () => {
    expect(CodeVerifier.safeParse(verifier).success).toBe(true);
    expect(CodeChallenge.safeParse(challenge).success).toBe(true);
  });

  it.each(["", "short", `${challenge}=`, `${challenge}x`, "a".repeat(42) + "+"])(
    "refuses the challenge %j",
    (value) => {
      expect(CodeChallenge.safeParse(value).success).toBe(false);
    },
  );

  it.each(["", "a".repeat(42), "a".repeat(129), "a".repeat(43) + " "])(
    "refuses the verifier %j",
    (value) => {
      expect(CodeVerifier.safeParse(value).success).toBe(false);
    },
  );
});
