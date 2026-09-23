import { describe, expect, it } from "vitest";
import {
  filterObligationRows,
  matchesObligationQuery,
  obligationKindTitle,
  obligationSettlementStatusBadge,
  obligationStatusBadge,
  parseObligationStatusFilter,
} from "./obligationList";
import type { ObligationRow } from "@/schemas/financing";

function row(overrides: Partial<ObligationRow> = {}): ObligationRow {
  return {
    obligation_id: "11111111-1111-1111-1111-111111111111",
    obligation_number: "OB-2026-0001",
    kind: "receivable",
    status: "open",
    counterparty_name: "Budi Santoso",
    purpose: "Pinjaman karyawan",
    obligation_date: "2026-01-10",
    due_date: "2026-06-10",
    principal: "5000000",
    outstanding: "3000000",
    overdue: false,
    source_type: "manual",
    related_entity_id: null,
    journal_id: "22222222-2222-2222-2222-222222222222",
    ...overrides,
  };
}

describe("obligationStatusBadge", () => {
  it("labels settled and void with their own fixed tone", () => {
    expect(obligationStatusBadge("settled", false)).toEqual({ text: "Lunas", tone: "success" });
    expect(obligationStatusBadge("void", false)).toEqual({ text: "Dibatalkan", tone: "neutral" });
    expect(obligationStatusBadge("void", true)).toEqual({ text: "Dibatalkan", tone: "neutral" });
  });

  it("shows an open obligation as attention, or critical once overdue", () => {
    expect(obligationStatusBadge("open", false)).toEqual({ text: "Berjalan", tone: "attention" });
    expect(obligationStatusBadge("open", true)).toEqual({ text: "Terlambat", tone: "critical" });
  });
});

describe("matchesObligationQuery / filterObligationRows", () => {
  it("matches the obligation number, counterparty or purpose, case-insensitively", () => {
    expect(matchesObligationQuery(row(), "ob-2026")).toBe(true);
    expect(matchesObligationQuery(row(), "budi")).toBe(true);
    expect(matchesObligationQuery(row(), "karyawan")).toBe(true);
    expect(matchesObligationQuery(row(), "tidak ada")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesObligationQuery(row(), "")).toBe(true);
  });

  it("filters a list down to the matches", () => {
    const rows = [
      row({ obligation_id: "1", counterparty_name: "Budi Santoso" }),
      row({ obligation_id: "2", counterparty_name: "Koperasi Sejahtera" }),
    ];
    expect(filterObligationRows(rows, "koperasi").map((r) => r.obligation_id)).toEqual(["2"]);
  });
});

describe("parseObligationStatusFilter", () => {
  it("accepts a listed status and rejects anything else", () => {
    expect(parseObligationStatusFilter("open")).toBe("open");
    expect(parseObligationStatusFilter("not_a_status")).toBeUndefined();
  });
});

describe("obligationKindTitle", () => {
  it("labels each kind", () => {
    expect(obligationKindTitle("receivable")).toBe("Piutang lain-lain");
    expect(obligationKindTitle("payable")).toBe("Utang lain-lain");
  });
});

describe("obligationSettlementStatusBadge", () => {
  it("labels and tones every settlement status", () => {
    expect(obligationSettlementStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(obligationSettlementStatusBadge("reversed")).toEqual({
      text: "Dibalik",
      tone: "attention",
    });
  });
});
