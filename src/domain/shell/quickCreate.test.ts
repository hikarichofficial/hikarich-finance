import { describe, expect, it } from "vitest";
import { QUICK_CREATE_REGISTRY, visibleQuickCreate } from "./quickCreate";

describe("QUICK_CREATE_REGISTRY", () => {
  it("has exactly the four OWNER-approved entries, in order (DECISIONS 199)", () => {
    expect(QUICK_CREATE_REGISTRY.map((item) => item.label)).toEqual([
      "Transfer Uang Baru",
      "Anggaran Baru",
      "Transaksi Berulang Baru",
      "Target Pendapatan Baru",
    ]);
  });

  it("points each entry at its own existing /new route", () => {
    expect(QUICK_CREATE_REGISTRY.map((item) => item.href)).toEqual([
      "/money/transfers/new",
      "/planning/budgets/new",
      "/planning/recurring/new",
      "/planning/targets/new",
    ]);
  });

  it("gates each entry on the exact permission its /new route requires", () => {
    expect(QUICK_CREATE_REGISTRY.map((item) => item.permission)).toEqual([
      "money.transfer_create",
      "planning.budget_edit",
      "planning.recurring_edit",
      "planning.budget_edit",
    ]);
  });
});

describe("visibleQuickCreate", () => {
  it("returns nothing for a membership with no relevant permission", () => {
    expect(visibleQuickCreate([])).toEqual([]);
    expect(visibleQuickCreate(["accounting.view"])).toEqual([]);
  });

  it("returns every entry for a membership holding every permission (e.g. OWNER)", () => {
    expect(visibleQuickCreate(QUICK_CREATE_REGISTRY.map((item) => item.permission))).toEqual(
      QUICK_CREATE_REGISTRY,
    );
  });

  it("returns only the entries a partial permission set unlocks, preserving registry order", () => {
    const result = visibleQuickCreate(["planning.recurring_edit", "money.transfer_create"]);
    expect(result.map((item) => item.label)).toEqual([
      "Transfer Uang Baru",
      "Transaksi Berulang Baru",
    ]);
  });

  it("a single shared permission unlocks both entries that require it", () => {
    const result = visibleQuickCreate(["planning.budget_edit"]);
    expect(result.map((item) => item.label)).toEqual(["Anggaran Baru", "Target Pendapatan Baru"]);
  });
});
