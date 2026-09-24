import { describe, expect, it } from "vitest";
import {
  equityPaymentStatusBadge,
  equityRetainedEarningsBadge,
  equityStatusBadge,
  filterEquityRows,
  matchesEquityQuery,
  parseEquityKindFilter,
  parseEquityStatusFilter,
} from "./equityList";
import type { EquityRow } from "@/schemas/financing";

function row(overrides: Partial<EquityRow> = {}): EquityRow {
  return {
    event_id: "11111111-1111-1111-1111-111111111111",
    event_number: "EQ-2026-0001",
    kind: "contribution",
    status: "confirmed",
    event_date: "2026-01-10",
    amount: "100000000",
    counterparty_name: "Hikari Sato",
    purpose: "Setoran modal awal",
    equity_class: "capital",
    resolution_reference: null,
    outstanding: null,
    exceeds_retained_earnings: null,
    tax_status: "not_applicable",
    related_entity_id: null,
    journal_id: "22222222-2222-2222-2222-222222222222",
    ...overrides,
  };
}

describe("equityStatusBadge", () => {
  it("labels and tones every status", () => {
    expect(equityStatusBadge("confirmed")).toEqual({ text: "Terkonfirmasi", tone: "success" });
    expect(equityStatusBadge("draft").tone).toBe("neutral");
    expect(equityStatusBadge("reversed").tone).toBe("attention");
    expect(equityStatusBadge("cancelled").tone).toBe("critical");
  });
});

describe("equityRetainedEarningsBadge", () => {
  it("flags a dividend that exceeds retained earnings, null otherwise", () => {
    expect(equityRetainedEarningsBadge(true)).toEqual({
      text: "Melebihi Laba Ditahan",
      tone: "critical",
    });
    expect(equityRetainedEarningsBadge(false)).toBeNull();
    expect(equityRetainedEarningsBadge(null)).toBeNull();
  });
});

describe("matchesEquityQuery / filterEquityRows", () => {
  it("matches the event number, counterparty or purpose, case-insensitively", () => {
    expect(matchesEquityQuery(row(), "eq-2026")).toBe(true);
    expect(matchesEquityQuery(row(), "hikari")).toBe(true);
    expect(matchesEquityQuery(row(), "setoran modal")).toBe(true);
    expect(matchesEquityQuery(row(), "tidak ada")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesEquityQuery(row(), "")).toBe(true);
  });

  it("filters a list down to the matches", () => {
    const rows = [
      row({ event_id: "1", counterparty_name: "Hikari Sato" }),
      row({ event_id: "2", counterparty_name: "Budi Santoso" }),
    ];
    expect(filterEquityRows(rows, "budi").map((r) => r.event_id)).toEqual(["2"]);
  });
});

describe("parseEquityKindFilter / parseEquityStatusFilter", () => {
  it("accepts a listed kind and rejects anything else", () => {
    expect(parseEquityKindFilter("dividend")).toBe("dividend");
    expect(parseEquityKindFilter("not_a_kind")).toBeUndefined();
  });

  it("accepts a listed status and rejects anything else", () => {
    expect(parseEquityStatusFilter("confirmed")).toBe("confirmed");
    expect(parseEquityStatusFilter("not_a_status")).toBeUndefined();
  });
});

describe("equityPaymentStatusBadge", () => {
  it("labels and tones every payment status", () => {
    expect(equityPaymentStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(equityPaymentStatusBadge("reversed")).toEqual({ text: "Dibalik", tone: "attention" });
  });
});
