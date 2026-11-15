import { describe, expect, it } from "vitest";
import { bearerToken, expiry } from "../src/session";

describe("bearerToken", () => {
  it("reads the token", () => {
    expect(bearerToken("Bearer ghr_abc")).toBe("ghr_abc");
  });

  it.each([null, "", "Bearer", "Bearer ", "bearer ghr_abc", "Basic ghr_abc", "Bearer a b"])(
    "finds none in %j",
    (header) => {
      expect(bearerToken(header)).toBeUndefined();
    },
  );
});

describe("expiry", () => {
  const early = { id: "early", expiresAt: 100 };
  const late = { id: "late", expiresAt: 200 };

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
