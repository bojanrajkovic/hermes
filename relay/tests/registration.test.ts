import { describe, expect, it } from "vitest";
import { decideRegistration } from "../src/registration";

const registration = {
  invite: "a-code",
  appID: 42,
  clientID: "Iv1.client",
  clientSecret: "client-secret",
  webhookSecret: "webhook-secret",
};

describe("decideRegistration", () => {
  it("takes a complete registration as a tenant's first", () => {
    expect(decideRegistration(registration, undefined)).toEqual({
      outcome: "first",
      registration,
    });
  });

  it("drops fields it does not know", () => {
    const decision = decideRegistration({ ...registration, pem: "private key" }, undefined);
    expect(decision).toEqual({ outcome: "first", registration });
  });

  it.each([
    ["no body", undefined],
    ["a missing invite", { ...registration, invite: undefined }],
    ["a missing secret", { ...registration, webhookSecret: undefined }],
    ["an empty secret", { ...registration, clientSecret: "" }],
    ["an App ID that is not a number", { ...registration, appID: "42" }],
  ])("calls %s invalid", (_name, body) => {
    expect(decideRegistration(body, undefined)).toEqual({ outcome: "invalid" });
  });

  it("recognizes the stored registration sent again", () => {
    expect(decideRegistration(registration, registration)).toEqual({ outcome: "repeated" });
  });

  it("refuses to replace a stored registration", () => {
    const other = { ...registration, webhookSecret: "another" };
    expect(decideRegistration(other, registration)).toEqual({ outcome: "alreadyRegistered" });
  });
});
