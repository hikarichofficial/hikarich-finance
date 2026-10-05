import { describe, expect, it } from "vitest";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";
import { mergeReconciliationListRows, reconciliationListStatus } from "./reconciliationList";

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

function status(overrides: Partial<ReconciliationStatusRow> = {}): ReconciliationStatusRow {
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

describe("mergeReconciliationListRows", () => {
  it("joins purely by financial_account_id and carries the account's currency", () => {
    const merged = mergeReconciliationListRows(
      [status({ financial_account_id: "a" })],
      [control({ financial_account_id: "a", currency: "USD" })],
    );
    expect(merged.find((r) => r.financial_account_id === "a")?.currency).toBe("USD");
  });

  it("drops an account that money_control no longer lists (archived by Hapus Rekening)", () => {
    const merged = mergeReconciliationListRows(
      [status({ financial_account_id: "a" }), status({ financial_account_id: "b" })],
      [control({ financial_account_id: "a", currency: "USD" })],
    );
    expect(merged.map((r) => r.financial_account_id)).toEqual(["a"]);
  });
});

describe("reconciliationListStatus", () => {
  it("prioritizes a session in progress over everything else", () => {
    expect(
      reconciliationListStatus(status({ session_in_progress: true, unresolved_lines: 3 })),
    ).toEqual({ text: "Sesi Berjalan", tone: "attention" });
  });

  it("surfaces unresolved lines when no session is marked in progress", () => {
    expect(
      reconciliationListStatus(status({ session_in_progress: false, unresolved_lines: 2 })),
    ).toEqual({ text: "2 Baris Belum Selesai", tone: "attention" });
  });

  it("labels an account never reconciled as progress", () => {
    expect(reconciliationListStatus(status({ last_reconciled_until: null }))).toEqual({
      text: "Belum Pernah Direkonsiliasi",
      tone: "progress",
    });
  });

  it("labels a clean, reconciled account as success", () => {
    expect(reconciliationListStatus(status())).toEqual({
      text: "Direkonsiliasi",
      tone: "success",
    });
  });
});
