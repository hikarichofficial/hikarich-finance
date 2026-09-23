import { describe, expect, it } from "vitest";
import {
  filterCashActivityRows,
  matchesAccountId,
  matchesCashActivityQuery,
  mergeCashActivityRows,
  type CashActivityRow,
} from "./cashActivity";
import type { MoneyControlRow, MoneyMovementRow } from "@/schemas/money";

function account(overrides: Partial<MoneyControlRow> = {}): MoneyControlRow {
  return {
    financial_account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    name: "Bank BCA",
    kind: "bank",
    currency: "IDR",
    is_active: true,
    movement_balance: "1000000",
    movement_base_balance: "1000000",
    ledger_balance: "1000000",
    difference: "0",
    is_negative: false,
    ...overrides,
  };
}

function movement(overrides: Partial<MoneyMovementRow> = {}): MoneyMovementRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    financial_account_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    currency: "IDR",
    direction: "in",
    amount: "500000",
    base_amount: "500000",
    movement_date: "2026-09-01",
    source_type: "vendor_payment",
    source_id: "22222222-2222-2222-2222-222222222222",
    component: "principal",
    journal_id: "33333333-3333-3333-3333-333333333333",
    reverses_movement_id: null,
    description: null,
    ...overrides,
  };
}

function row(overrides: Partial<CashActivityRow> = {}): CashActivityRow {
  return {
    ...movement(),
    account_name: "Bank BCA",
    account_currency: "IDR",
    journal_number: "JRN-2026-0001",
    ...overrides,
  };
}

describe("mergeCashActivityRows", () => {
  it("resolves account name/currency and journal number by joining against the given lookups", () => {
    const merged = mergeCashActivityRows(
      [movement({ financial_account_id: "a", journal_id: "j1" })],
      [
        account({
          financial_account_id: "a",
          name: "Bank Mandiri",
          currency: "USD",
        }),
      ],
      new Map([["j1", "JRN-2026-0042"]]),
    );
    expect(merged[0].account_name).toBe("Bank Mandiri");
    expect(merged[0].account_currency).toBe("USD");
    expect(merged[0].journal_number).toBe("JRN-2026-0042");
  });

  it("falls back to a generic account label and the movement's own currency when the account is missing", () => {
    const merged = mergeCashActivityRows(
      [movement({ financial_account_id: "missing", currency: "USD" })],
      [],
      new Map(),
    );
    expect(merged[0].account_name).toBe("Akun tidak dikenal");
    expect(merged[0].account_currency).toBe("USD");
  });

  it("resolves a missing journal number to null rather than throwing", () => {
    const merged = mergeCashActivityRows(
      [movement({ journal_id: "j1" })],
      [account()],
      new Map(),
    );
    expect(merged[0].journal_number).toBeNull();
  });
});

describe("matchesAccountId / filterCashActivityRows", () => {
  const rows = [
    row({ id: "x", financial_account_id: "a" }),
    row({ id: "y", financial_account_id: "b" }),
  ];

  it("null matches every account", () => {
    expect(rows.filter((r) => matchesAccountId(r, null))).toHaveLength(2);
  });

  it("a specific account id matches only that account", () => {
    expect(
      rows.filter((r) => matchesAccountId(r, "b")).map((r) => r.id),
    ).toEqual(["y"]);
  });

  it("filterCashActivityRows combines the account filter and the query", () => {
    const withNames = [
      row({ id: "x", financial_account_id: "a", account_name: "Bank Mandiri" }),
      row({ id: "y", financial_account_id: "b", account_name: "Kas Kecil" }),
    ];
    expect(filterCashActivityRows(withNames, "a", "")).toEqual([withNames[0]]);
    expect(filterCashActivityRows(withNames, null, "kas kecil")).toEqual([
      withNames[1],
    ]);
  });
});

describe("matchesCashActivityQuery", () => {
  it("matches the account name, the humanized source type, the description or the journal number", () => {
    expect(
      matchesCashActivityQuery(
        row({ account_name: "Bank Mandiri" }),
        "mandiri",
      ),
    ).toBe(true);
    expect(
      matchesCashActivityQuery(
        row({ source_type: "vendor_payment" }),
        "pembayaran vendor",
      ),
    ).toBe(true);
    expect(
      matchesCashActivityQuery(
        row({ description: "Bayar sewa kantor" }),
        "sewa",
      ),
    ).toBe(true);
    expect(
      matchesCashActivityQuery(
        row({ journal_number: "JRN-2026-0099" }),
        "0099",
      ),
    ).toBe(true);
    expect(matchesCashActivityQuery(row(), "tidak-ada")).toBe(false);
  });

  it("a null journal_number never matches a journal-number query", () => {
    expect(matchesCashActivityQuery(row({ journal_number: null }), "jrn")).toBe(
      false,
    );
  });
});
