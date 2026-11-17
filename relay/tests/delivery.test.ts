import { describe, expect, it } from "vitest";
import { classifyDelivery } from "../src/delivery";

const repository = { id: 7, full_name: "acme/site" };

const body = (payload: unknown) => JSON.stringify(payload);

describe("classifyDelivery", () => {
  it.each(["pull_request", "issue_comment", "check_run", "status", "some_future_event"])(
    "forwards %s for its repository",
    (event) => {
      const action = classifyDelivery(event, body({ action: "created", repository }));
      expect(action).toEqual({ action: "forward", repository: 7 });
    },
  );

  it.each([
    "installation_repositories",
    "member",
    "membership",
    "organization",
    "repository",
    "team",
    "team_add",
  ])("re-checks access on %s", (event) => {
    expect(classifyDelivery(event, body({ action: "removed", repository }))).toEqual({
      action: "recheck",
    });
  });

  it("deletes the tenant when the App is uninstalled", () => {
    expect(classifyDelivery("installation", body({ action: "deleted" }))).toEqual({
      action: "delete",
    });
  });

  it("reads an event whose repository is null", () => {
    expect(classifyDelivery("installation", body({ action: "deleted", repository: null }))).toEqual(
      {
        action: "delete",
      },
    );
    expect(
      classifyDelivery("organization", body({ action: "member_removed", repository: null })),
    ).toEqual({ action: "recheck" });
  });

  it.each(["created", "suspend", "unsuspend", "new_permissions_accepted"])(
    "ignores installation %s",
    (action) => {
      expect(classifyDelivery("installation", body({ action }))).toEqual({ action: "ignore" });
    },
  );

  it("ignores a delivery that names no repository", () => {
    expect(classifyDelivery("ping", body({ zen: "Keep it simple." }))).toEqual({
      action: "ignore",
    });
  });

  it("ignores a body that is not a JSON object", () => {
    expect(classifyDelivery("pull_request", "{not json")).toEqual({ action: "ignore" });
    expect(classifyDelivery("pull_request", "null")).toEqual({ action: "ignore" });
  });
});
