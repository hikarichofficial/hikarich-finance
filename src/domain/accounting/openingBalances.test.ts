import { describe, expect, it } from "vitest";
import type { LedgerAccountRow } from "@/schemas/accounting";
import {
  checkOpeningLines,
  openingAccountOptions,
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

describe("openingAccountOptions (finding #91)", () => {
  const acct = (over: Partial<LedgerAccountRow>): LedgerAccountRow => ({
    id: "00000000-0000-4000-8000-000000000001",
    entity_id: "00000000-0000-4000-8000-0000000000e1",
    code: "1000",
    name: "Akun",
    account_class: "asset",
    normal_balance: "debit",
    system_key: null,
    parent_id: null,
    is_group: false,
    is_control: false,
    allows_manual_posting: true,
    status: "active",
    ...over,
  });
  const group = acct({ id: "00000000-0000-4000-8000-0000000000a1", code: "1100", is_group: true });
  const unlinkedCash = acct({
    id: "00000000-0000-4000-8000-0000000000a2",
    code: "1110",
    name: "Kas Tunai",
    parent_id: group.id,
  });
  const linkedBank = acct({
    id: "00000000-0000-4000-8000-0000000000a3",
    code: "1121",
    name: "BCA",
    parent_id: group.id,
  });
  const linkedUsd = acct({
    id: "00000000-0000-4000-8000-0000000000a4",
    code: "1122",
    name: "Bank USD",
    parent_id: group.id,
  });
  const equity = acct({
    id: "00000000-0000-4000-8000-0000000000a5",
    code: "3100",
    name: "Modal",
    account_class: "equity",
  });
  const links = [
    { ledger_account_id: linkedBank.id, name: "BCA", currency: "IDR" },
    { ledger_account_id: linkedUsd.id, name: "Bank USD", currency: "USD" },
  ];

  it("drops unlinked default cash accounts, labels real ones, disables foreign-currency ones", () => {
    const result = openingAccountOptions(
      [group, unlinkedCash, linkedBank, linkedUsd, equity],
      links,
      "IDR",
    );
    expect(result.map((o) => o.account.code)).toEqual(["1121", "1122", "3100"]);
    expect(result[0]).toMatchObject({ hint: "rekening kas/bank", disabled: false });
    expect(result[1].disabled).toBe(true);
    expect(result[2]).toMatchObject({ hint: null, disabled: false });
  });
});
