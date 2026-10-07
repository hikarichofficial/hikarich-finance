import { describe, expect, it } from "vitest";
import { IdentityError, identityFailure } from "./identityFailure";

describe("identity save refusals (decision 317)", () => {
  it("tells the refusals of update_entity_identity apart", () => {
    expect(identityFailure("CONFLICT: the Entity changed since it was loaded")).toBe("conflict");
    expect(identityFailure("INVALID: the email address is not valid")).toBe("email");
    expect(identityFailure("INVALID: a name, address or contact detail is too long")).toBe(
      "too_long",
    );
    expect(identityFailure("INVALID: the legal name must be 1 to 200 characters")).toBe(
      "legal_name",
    );
    expect(identityFailure("something unexpected")).toBe("other");
  });

  it("keeps the database text for the developer, not for the person", () => {
    const error = new IdentityError("other", "boom");
    expect(error.detail).toBe("boom");
    expect(error.message).not.toContain("boom");
  });
});
