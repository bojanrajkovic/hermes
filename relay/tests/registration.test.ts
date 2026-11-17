import { describe, expect, it } from "vitest";
import { decideRegistration, inviteAccepted } from "../src/registration";

const codes = "first-code, second-code";
const registration = {
  invite: "first-code",
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

describe("inviteAccepted", () => {
  it("accepts each listed code, ignoring spaces around commas", () => {
    expect(inviteAccepted(codes, "first-code")).toBe(true);
    expect(inviteAccepted(codes, "second-code")).toBe(true);
  });

  it("refuses a code that is not listed", () => {
    expect(inviteAccepted(codes, "third-code")).toBe(false);
    expect(inviteAccepted(codes, "first")).toBe(false);
  });

  it("accepts nothing when no codes are set", () => {
    expect(inviteAccepted("", "")).toBe(false);
    expect(inviteAccepted(" , ", "")).toBe(false);
  });
});

describe("decideRegistration", () => {
  it("accepts a complete registration with a listed invite", () => {
    expect(decideRegistration(registration, codes, undefined)).toEqual({
      outcome: "accepted",
      registration,
    });
  });

  it("drops fields it does not know", () => {
    const decision = decideRegistration({ ...registration, pem: "private key" }, codes, undefined);
    expect(decision).toEqual({ outcome: "accepted", registration });
  });

  it.each([
    ["no body", undefined],
    ["a missing secret", { ...registration, webhookSecret: undefined }],
    ["an empty secret", { ...registration, clientSecret: "" }],
    ["an App ID that is not a number", { ...registration, appID: "42" }],
  ])("calls %s invalid", (_name, body) => {
    expect(decideRegistration(body, codes, undefined)).toEqual({ outcome: "invalid" });
  });

  it("refuses an invite that is not listed", () => {
    const decision = decideRegistration({ ...registration, invite: "nope" }, codes, undefined);
    expect(decision).toEqual({ outcome: "inviteRefused" });
  });

  it("accepts the stored registration again", () => {
    expect(decideRegistration(registration, codes, registration).outcome).toBe("accepted");
  });

  it("refuses to replace a stored registration", () => {
    const other = { ...registration, webhookSecret: "another" };
    expect(decideRegistration(other, codes, registration)).toEqual({
      outcome: "alreadyRegistered",
    });
  });
});
