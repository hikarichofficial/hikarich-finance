import { describe, expect, it } from "vitest";
import type { LedgerAccountRow } from "@/schemas/accounting";
import {
  checkOpeningLines,
  openingEligibleAccounts,
  type OpeningLineDraft,
} from "./openingBalances";

const A = "0f8fad5b-d9cb-469f-a165-70867728950e";
const B = "7c9e6679-7425-40de-944b-e07fc1f90ae7";

function draft(overrides: Partial<OpeningLineDraft>): OpeningLineDraft {
  return { key: "k", account_id: "", debit: "", credit: "", description: "", ...overrides };
}

function account(overrides: Partial<LedgerAccountRow>): LedgerAccountRow {
  return {
    id: A,
    entity_id: B,
    code: "1100",
    name: "Kas",
    account_class: "asset",
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

describe("openingEligibleAccounts", () => {
  it("keeps only active, postable balance-sheet accounts other than the clearing account", () => {
    const rows = [
      account({ code: "1100" }),
      account({ code: "1000", is_group: true }),
      account({ code: "4100", account_class: "revenue" }),
      account({ code: "3900", account_class: "equity", system_key: "OPENING_BALANCE_CLEARING" }),
      account({ code: "2100", account_class: "liability", status: "inactive" }),
      account({ code: "3100", account_class: "equity" }),
    ];
    expect(openingEligibleAccounts(rows).map((a) => a.code)).toEqual(["1100", "3100"]);
  });
});

describe("checkOpeningLines", () => {
  it("builds RPC lines and the clearing difference", () => {
    const result = checkOpeningLines([
      draft({ account_id: A, debit: "1000", description: " Kas awal " }),
      draft({ account_id: B, credit: "400.5" }),
      draft({}),
    ]);
    expect(result.problems).toEqual([]);
    expect(result.lines).toEqual([
      { account_id: A, debit: "1000", description: "Kas awal" },
      { account_id: B, credit: "400.5" },
    ]);
    expect(result.totalDebit).toBe("1000.0000");
    expect(result.totalCredit).toBe("400.5000");
    expect(result.difference).toBe("599.5000");
  });

  it("reports a missing account, both sides filled, bad numbers and an empty form", () => {
    expect(checkOpeningLines([draft({ debit: "5" })]).problems).toContain("Baris 1: pilih akun.");
    expect(
      checkOpeningLines([draft({ account_id: A, debit: "5", credit: "5" })]).problems,
    ).toContain("Baris 1: isi tepat satu dari Debit atau Kredit.");
    expect(checkOpeningLines([draft({ account_id: A, debit: "1,5" })]).problems).toContain(
      "Baris 1: Debit harus angka (maks. 4 desimal).",
    );
    expect(checkOpeningLines([draft({})]).problems).toContain("Isi minimal satu baris saldo awal.");
  });

  it("treats a zero amount as empty", () => {
    expect(checkOpeningLines([draft({ account_id: A, debit: "0" })]).problems).toContain(
      "Baris 1: isi tepat satu dari Debit atau Kredit.",
    );
  });
});
