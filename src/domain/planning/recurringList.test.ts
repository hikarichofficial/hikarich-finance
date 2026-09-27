import { describe, expect, it } from "vitest";
import {
  RECURRING_STATUS_FILTER_OPTIONS,
  filterRecurringRows,
  matchesRecurringQuery,
  parseRecurringStatusFilter,
  recurringOccurrenceStatusBadge,
  recurringStatusBadge,
} from "./recurringList";
import type { RecurringRuleRow } from "@/schemas/planning";

function row(overrides: Partial<RecurringRuleRow> = {}): RecurringRuleRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "22222222-2222-2222-2222-222222222222",
    kind: "invoice",
    label: "Sewa Kantor Bulanan",
    status: "active",
    frequency: "monthly",
    interval_count: 1,
    due_offset_days: 7,
    start_date: "2025-01-01",
    end_date: null,
    next_occurrence_date: "2025-08-01",
    last_generated_date: "2025-07-01",
    template: {},
    note: null,
    paused_at: null,
    paused_reason: null,
    ended_at: null,
    ended_reason: null,
    version: 1,
    ...overrides,
  };
}

describe("recurringStatusBadge", () => {
  it("returns the Indonesian label and tone for each status", () => {
    expect(recurringStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(recurringStatusBadge("paused")).toEqual({ text: "Dijeda", tone: "attention" });
    expect(recurringStatusBadge("ended")).toEqual({ text: "Berakhir", tone: "neutral" });
  });
});

describe("RECURRING_STATUS_FILTER_OPTIONS", () => {
  it("starts with the all-status option and lists all three statuses", () => {
    expect(RECURRING_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
    expect(RECURRING_STATUS_FILTER_OPTIONS).toHaveLength(4);
  });
});

describe("parseRecurringStatusFilter", () => {
  it("parses a known status and treats anything else as no filter", () => {
    expect(parseRecurringStatusFilter("paused")).toBe("paused");
    expect(parseRecurringStatusFilter(undefined)).toBeUndefined();
    expect(parseRecurringStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesRecurringQuery", () => {
  it("matches the rule's own label, case-insensitively", () => {
    expect(matchesRecurringQuery(row(), "sewa kantor")).toBe(true);
    expect(matchesRecurringQuery(row(), "SEWA")).toBe(true);
    expect(matchesRecurringQuery(row(), "listrik")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesRecurringQuery(row(), "  ")).toBe(true);
  });
});

describe("filterRecurringRows", () => {
  it("filters by the free-text label query", () => {
    const rows = [
      row({ id: "1", label: "Sewa Kantor Bulanan" }),
      row({ id: "2", label: "Langganan Internet" }),
    ];
    expect(filterRecurringRows(rows, "internet").map((r) => r.id)).toEqual(["2"]);
    expect(filterRecurringRows(rows, "").map((r) => r.id)).toEqual(["1", "2"]);
  });
});

describe("recurringOccurrenceStatusBadge", () => {
  it("returns the Indonesian label and tone for each occurrence status", () => {
    expect(recurringOccurrenceStatusBadge("generated")).toEqual({
      text: "Berhasil dibuat",
      tone: "success",
    });
    expect(recurringOccurrenceStatusBadge("failed")).toEqual({ text: "Gagal", tone: "critical" });
  });
});
