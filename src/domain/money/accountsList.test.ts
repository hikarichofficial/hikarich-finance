import { describe, expect, it } from "vitest";
import {
  accountListStatus,
  filterAccountRows,
  matchesAccountFilter,
  matchesAccountQuery,
  mergeAccountRows,
  parseAccountFilter,
  resolveActivityRange,
  sourceTypeLabel,
  type AccountListRow,
} from "./accountsList";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";

function control(overrides: Partial<MoneyControlRow> = {}): MoneyControlRow {
  return {
    financial_account_id: "11111111-1111-1111-1111-111111111111",
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

function reconciliation(overrides: Partial<ReconciliationStatusRow> = {}): ReconciliationStatusRow {
  return {
    financial_account_id: "11111111-1111-1111-1111-111111111111",
    name: "Bank BCA",
    last_reconciled_until: "2026-08-31",
    last_statement_closing: "1000000",
    session_in_progress: false,
    unresolved_lines: 0,
    outstanding_movements: 0,
    last_difference: "0",
    ...overrides,
  };
}

function row(overrides: Partial<AccountListRow> = {}): AccountListRow {
  return { ...control(), reconciliation: reconciliation(), ...overrides };
}

describe("mergeAccountRows", () => {
  it("joins purely by financial_account_id, keeping every control row even without a match", () => {
    const merged = mergeAccountRows(
      [control({ financial_account_id: "a" }), control({ financial_account_id: "b" })],
      [reconciliation({ financial_account_id: "a" })],
    );
    expect(merged.map((r) => r.financial_account_id)).toEqual(["a", "b"]);
    expect(merged[0].reconciliation).not.toBeNull();
    expect(merged[1].reconciliation).toBeNull();
  });
});

describe("accountListStatus", () => {
  it("labels an inactive account as neutral regardless of everything else", () => {
    expect(
      accountListStatus(row({ is_active: false, difference: "500", reconciliation: null })),
    ).toEqual({ text: "Tidak Aktif", tone: "neutral" });
  });

  it("labels a ledger difference as critical even when reconciled", () => {
    expect(accountListStatus(row({ difference: "1500" }))).toEqual({
      text: "Selisih dengan Buku Besar",
      tone: "critical",
    });
  });

  it("labels an in-progress reconciliation session as attention", () => {
    expect(
      accountListStatus(row({ reconciliation: reconciliation({ session_in_progress: true }) })),
    ).toEqual({ text: "Sesi rekonsiliasi berjalan", tone: "attention" });
  });

  it("labels unresolved lines as attention with the count", () => {
    expect(
      accountListStatus(row({ reconciliation: reconciliation({ unresolved_lines: 3 }) })),
    ).toEqual({ text: "3 baris belum selesai", tone: "attention" });
  });

  it("labels a never-reconciled account as progress", () => {
    expect(
      accountListStatus(row({ reconciliation: reconciliation({ last_reconciled_until: null }) })),
    ).toEqual({ text: "Belum pernah direkonsiliasi", tone: "progress" });
    expect(accountListStatus(row({ reconciliation: null }))).toEqual({
      text: "Belum pernah direkonsiliasi",
      tone: "progress",
    });
  });

  it("labels a clean, reconciled account as success", () => {
    expect(accountListStatus(row())).toEqual({ text: "Direkonsiliasi", tone: "success" });
  });
});

describe("matchesAccountFilter / filterAccountRows", () => {
  const rows = [
    row({ financial_account_id: "a", is_active: true, difference: "0" }),
    row({ financial_account_id: "b", is_active: false }),
    row({ financial_account_id: "c", difference: "100" }),
    row({
      financial_account_id: "d",
      reconciliation: reconciliation({ last_reconciled_until: null }),
    }),
  ];

  it("null filter matches everything", () => {
    expect(rows.filter((r) => matchesAccountFilter(r, null))).toHaveLength(rows.length);
  });

  it("active/inactive partition the set", () => {
    expect(
      rows.filter((r) => matchesAccountFilter(r, "active")).map((r) => r.financial_account_id),
    ).toEqual(["a", "c", "d"]);
    expect(
      rows.filter((r) => matchesAccountFilter(r, "inactive")).map((r) => r.financial_account_id),
    ).toEqual(["b"]);
  });

  it("difference matches a non-zero ledger difference", () => {
    expect(
      rows.filter((r) => matchesAccountFilter(r, "difference")).map((r) => r.financial_account_id),
    ).toEqual(["c"]);
  });

  it("unreconciled matches a null last_reconciled_until", () => {
    expect(
      rows
        .filter((r) => matchesAccountFilter(r, "unreconciled"))
        .map((r) => r.financial_account_id),
    ).toEqual(["d"]);
  });

  it("filterAccountRows combines filter and query", () => {
    const withNames = [
      row({ financial_account_id: "x", name: "Bank Mandiri" }),
      row({ financial_account_id: "y", name: "Kas Kecil", kind: "cash" }),
    ];
    expect(filterAccountRows(withNames, null, "mandiri")).toEqual([withNames[0]]);
    expect(filterAccountRows(withNames, null, "cash")).toEqual([withNames[1]]);
  });
});

describe("parseAccountFilter", () => {
  it("accepts a known value and rejects unknown/absent ones", () => {
    expect(parseAccountFilter("difference")).toBe("difference");
    expect(parseAccountFilter("bogus")).toBeUndefined();
    expect(parseAccountFilter(undefined)).toBeUndefined();
  });
});

describe("matchesAccountQuery", () => {
  it("matches case-insensitively on name or kind", () => {
    expect(matchesAccountQuery(row({ name: "Bank BCA", kind: "bank" }), "bca")).toBe(true);
    expect(matchesAccountQuery(row({ name: "Kas Kecil", kind: "cash" }), "cash")).toBe(true);
    expect(matchesAccountQuery(row(), "tidak-ada")).toBe(false);
  });
});

describe("sourceTypeLabel", () => {
  it("returns the known Indonesian label for a recognized source type", () => {
    expect(sourceTypeLabel("vendor_payment")).toBe("Pembayaran Vendor");
    expect(sourceTypeLabel("opening_balance")).toBe("Saldo Awal");
  });

  it("falls back to a title-cased version of an unrecognized source type", () => {
    expect(sourceTypeLabel("asset_disposal")).toBe("Asset Disposal");
    expect(sourceTypeLabel("equity_event")).toBe("Equity Event");
  });
});

describe("resolveActivityRange", () => {
  const reference = new Date("2026-09-23T12:00:00Z");

  it("uses a valid from/to pair as given", () => {
    expect(resolveActivityRange("2026-09-01", "2026-09-15", reference)).toEqual({
      from: "2026-09-01",
      to: "2026-09-15",
    });
  });

  it("falls back to a trailing 30-day window when from/to are absent", () => {
    expect(resolveActivityRange(undefined, undefined, reference)).toEqual({
      from: "2026-08-25",
      to: "2026-09-23",
    });
  });

  it("falls back when the pair is inverted (from after to)", () => {
    expect(resolveActivityRange("2026-09-20", "2026-09-01", reference)).toEqual({
      from: "2026-08-25",
      to: "2026-09-23",
    });
  });

  it("falls back when either value is malformed", () => {
    expect(resolveActivityRange("not-a-date", "2026-09-15", reference)).toEqual({
      from: "2026-08-25",
      to: "2026-09-23",
    });
  });

  it("accepts from equal to to as a single-day range", () => {
    expect(resolveActivityRange("2026-09-10", "2026-09-10", reference)).toEqual({
      from: "2026-09-10",
      to: "2026-09-10",
    });
  });
});
