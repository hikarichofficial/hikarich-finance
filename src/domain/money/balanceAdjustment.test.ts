import { describe, expect, it } from "vitest";
import type { LedgerAccountRow } from "@/schemas/accounting";
import { eligibleCounterAccounts } from "./balanceAdjustment";

function account(overrides: Partial<LedgerAccountRow> = {}): LedgerAccountRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "22222222-2222-2222-2222-222222222222",
    code: "6-1000",
    name: "Biaya Administrasi",
    account_class: "expense",
    normal_balance: "debit",
    system_key: null,
    parent_id: null,
    is_group: false,
    is_control: false,
    allows_manual_posting: true,
    status: "active",
    ...overrides,
  };
}

describe("eligibleCounterAccounts", () => {
  it("keeps a plain active, non-group, non-control account", () => {
    const result = eligibleCounterAccounts([account()]);
    expect(result).toHaveLength(1);
  });

  it("excludes an inactive account", () => {
    const result = eligibleCounterAccounts([account({ status: "inactive" })]);
    expect(result).toHaveLength(0);
  });

  it("excludes a group (header) account", () => {
    const result = eligibleCounterAccounts([account({ is_group: true })]);
    expect(result).toHaveLength(0);
  });

  it("excludes a control account", () => {
    const result = eligibleCounterAccounts([account({ is_control: true })]);
    expect(result).toHaveLength(0);
  });

  it("excludes the opening-balance clearing account specifically", () => {
    const result = eligibleCounterAccounts([account({ system_key: "OPENING_BALANCE_CLEARING" })]);
    expect(result).toHaveLength(0);
  });

  it("does not require allows_manual_posting, since the RPC itself does not check it", () => {
    const result = eligibleCounterAccounts([account({ allows_manual_posting: false })]);
    expect(result).toHaveLength(1);
  });
});
