import { describe, expect, it } from "vitest";
import { firstForwardedAddress, hashRequester } from "./requester";

describe("public requester hash", () => {
  it("is stable, 64 hex characters, and depends on the salt and the requester", () => {
    const a = hashRequester("salt-one-1234567890", "203.0.113.7", "Mozilla/5.0");
    expect(a).toMatch(/^[0-9a-f]{64}$/);
    expect(hashRequester("salt-one-1234567890", "203.0.113.7", "Mozilla/5.0")).toBe(a);
    expect(hashRequester("salt-two-1234567890", "203.0.113.7", "Mozilla/5.0")).not.toBe(a);
    expect(hashRequester("salt-one-1234567890", "203.0.113.8", "Mozilla/5.0")).not.toBe(a);
  });

  it("an unknown address still hashes", () => {
    expect(hashRequester("salt-one-1234567890", "  ", "x")).toMatch(/^[0-9a-f]{64}$/);
  });

  it("takes the first address of a forwarded list", () => {
    expect(firstForwardedAddress("203.0.113.7, 10.0.0.1")).toBe("203.0.113.7");
    expect(firstForwardedAddress(null)).toBe("");
  });
});
