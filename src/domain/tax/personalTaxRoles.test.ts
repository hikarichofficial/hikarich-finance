import { describe, expect, it } from "vitest";
import {
  PERSONAL_ROLE_LABELS,
  PERSONAL_TAX_ROLES,
  isPersonalTaxRole,
  personalRolesForKind,
  untaggedLabel,
} from "./personalTaxRoles";

describe("personal tax roles", () => {
  it("offers income roles for revenue and the cost role for expense, as the database enforces", () => {
    expect(personalRolesForKind("revenue")).toEqual([
      "umkm_business",
      "freelance",
      "company_payout",
    ]);
    expect(personalRolesForKind("expense")).toEqual(["business_cost"]);
    expect(personalRolesForKind("asset")).toEqual([]);
  });

  it("has a label for every role and recognises only real roles", () => {
    for (const role of PERSONAL_TAX_ROLES) expect(PERSONAL_ROLE_LABELS[role]).toBeTruthy();
    expect(isPersonalTaxRole("freelance")).toBe(true);
    expect(isPersonalTaxRole("x")).toBe(false);
  });

  it("words the untagged choice by kind", () => {
    expect(untaggedLabel("expense")).toContain("tidak mengurangi pajak");
    expect(untaggedLabel("revenue")).toContain("tidak dihitung pajak");
  });
});
