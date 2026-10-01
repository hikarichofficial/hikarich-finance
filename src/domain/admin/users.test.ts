import { describe, expect, it } from "vitest";
import { effectivePermissions, parsePageOffset, userAdminActions } from "./users";

describe("effectivePermissions", () => {
  it("combines role permissions with grant and deny overrides", () => {
    expect(
      effectivePermissions(
        ["bills.view", "invoices.view"],
        [
          { permission_key: "bills.pay", effect: "grant", reason: null },
          { permission_key: "invoices.view", effect: "deny", reason: "x" },
        ],
      ),
    ).toEqual([
      { key: "bills.pay", source: "grant", denied: false },
      { key: "bills.view", source: "role", denied: false },
      { key: "invoices.view", source: "role", denied: true },
    ]);
  });

  it("returns nothing for an empty role without overrides", () => {
    expect(effectivePermissions([], [])).toEqual([]);
  });
});

describe("userAdminActions", () => {
  const all = { canAssign: true, canDisable: true, canOverride: true };
  it("offers nothing on the person's own membership", () => {
    expect(userAdminActions(true, all)).toEqual({
      canAssign: false,
      canDisable: false,
      canOverride: false,
    });
  });
  it("passes permissions through for someone else", () => {
    expect(userAdminActions(false, all)).toEqual(all);
  });
});

describe("parsePageOffset", () => {
  it("accepts multiples of the page size only", () => {
    expect(parsePageOffset("100", 50)).toBe(100);
    expect(parsePageOffset("30", 50)).toBe(0);
    expect(parsePageOffset("-50", 50)).toBe(0);
    expect(parsePageOffset(undefined, 50)).toBe(0);
  });
});
