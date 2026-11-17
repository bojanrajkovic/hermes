import { describe, expect, it } from "vitest";
import { settingsProblems } from "../src/worker-settings";

// What Cloudflare returned for the deployed relay.
const relay = {
  annotations: {},
  bindings: [
    { name: "COMMIT", type: "plain_text" },
    { name: "INVITE_CODES", type: "secret_text" },
    { name: "TENANT", type: "durable_object_namespace" },
  ],
  compatibility_date: "2026-11-01",
  compatibility_flags: [],
  logpush: false,
  placement: {},
  tags: [],
  tail_consumers: [],
  usage_model: "standard",
};

describe("settingsProblems", () => {
  it("finds nothing wrong with the relay's own settings", () => {
    expect(settingsProblems(relay)).toEqual([]);
  });

  it("reports a Tail Worker", () => {
    const problems = settingsProblems({ ...relay, tail_consumers: [{ service: "listener" }] });
    expect(problems).toEqual(['tail_consumers is set: [{"service":"listener"}]']);
  });

  it("reports any other kind of tail consumer", () => {
    const problems = settingsProblems({
      ...relay,
      streaming_tail_consumers: [{ service: "listener" }],
    });
    expect(problems).toHaveLength(1);
  });

  it("reports log push and observability", () => {
    expect(settingsProblems({ ...relay, logpush: true })).toEqual(["logpush is on"]);
    expect(settingsProblems({ ...relay, observability: { enabled: true } })).toEqual([
      "observability is on",
    ]);
    expect(
      settingsProblems({ ...relay, observability: { enabled: false, logs: { enabled: true } } }),
    ).toEqual(["observability is on"]);
    expect(settingsProblems({ ...relay, observability: { enabled: false } })).toEqual([]);
  });

  it("reports a binding the relay does not have, and one it lacks", () => {
    const extra = [...relay.bindings, { name: "COPY", type: "r2_bucket" }];
    expect(settingsProblems({ ...relay, bindings: extra })).toHaveLength(1);
    expect(settingsProblems({ ...relay, bindings: relay.bindings.slice(1) })).toHaveLength(1);
  });

  it("reports an answer that is not settings", () => {
    expect(settingsProblems(null)).toEqual(["Cloudflare returned no settings"]);
  });
});
