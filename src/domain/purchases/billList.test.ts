import { describe, expect, it } from "vitest";
import {
  billActivityTimeline,
  billListStatus,
  filterBillRows,
  matchesBillFilter,
  matchesBillQuery,
  parseBillFilter,
  type BillListRow,
} from "./billList";

function row(overrides: Partial<BillListRow> = {}): BillListRow {
  return {
    bill_id: "11111111-1111-1111-1111-111111111111",
    bill_number: "BILL-2026-0001",
    vendor_id: "22222222-2222-2222-2222-222222222222",
    vendor_name: "CV Pemasok Utama",
    currency: "IDR",
    status: "approved",
    bill_date: "2026-09-01",
    due_date: "2026-09-15",
    total: "1000000",
    outstanding: "1000000",
    settlement_status: "unpaid",
    is_overdue: false,
    days_overdue: 0,
    ...overrides,
  };
}

describe("billListStatus", () => {
  it("labels draft as neutral", () => {
    expect(billListStatus(row({ status: "draft" }))).toEqual({
      text: "Draf",
      tone: "neutral",
    });
  });

  it("labels submitted as attention (awaiting approval)", () => {
    expect(billListStatus(row({ status: "submitted" }))).toEqual({
      text: "Menunggu persetujuan",
      tone: "attention",
    });
  });

  it("labels cancelled/void as neutral", () => {
    expect(billListStatus(row({ status: "cancelled" })).tone).toBe("neutral");
    expect(billListStatus(row({ status: "void" })).tone).toBe("neutral");
  });

  it("labels a paid approved bill as success even if is_overdue was left true", () => {
    expect(
      billListStatus(row({ settlement_status: "paid", is_overdue: true })),
    ).toEqual({ text: "Lunas", tone: "success" });
  });

  it("labels an overdue approved bill as critical with the day count", () => {
    expect(billListStatus(row({ is_overdue: true, days_overdue: 7 }))).toEqual({
      text: "Jatuh tempo 7 hari",
      tone: "critical",
    });
  });

  it("labels a partially paid, not-yet-due approved bill as progress", () => {
    expect(billListStatus(row({ settlement_status: "partial" }))).toEqual({
      text: "Dibayar sebagian",
      tone: "progress",
    });
  });

  it("labels an unpaid, not-yet-due approved bill as neutral", () => {
    expect(billListStatus(row())).toEqual({
      text: "Belum dibayar",
      tone: "neutral",
    });
  });
});

describe("matchesBillFilter / filterBillRows", () => {
  const rows = [
    row({ status: "draft", bill_id: "a" }),
    row({ status: "submitted", bill_id: "b" }),
    row({ status: "approved", settlement_status: "unpaid", bill_id: "c" }),
    row({ status: "approved", is_overdue: true, bill_id: "d" }),
    row({ status: "approved", settlement_status: "paid", bill_id: "e" }),
    row({ status: "void", bill_id: "f" }),
    row({ status: "cancelled", bill_id: "g" }),
  ];

  it("null filter matches everything", () => {
    expect(rows.filter((r) => matchesBillFilter(r, null))).toHaveLength(
      rows.length,
    );
  });

  it("pending_approval matches draft and submitted only", () => {
    const matched = rows.filter((r) =>
      matchesBillFilter(r, "pending_approval"),
    );
    expect(matched.map((r) => r.bill_id)).toEqual(["a", "b"]);
  });

  it("open matches approved, not-yet-paid bills", () => {
    const matched = rows.filter((r) => matchesBillFilter(r, "open"));
    expect(matched.map((r) => r.bill_id)).toEqual(["c", "d"]);
  });

  it("overdue matches only is_overdue rows", () => {
    expect(
      rows.filter((r) => matchesBillFilter(r, "overdue")).map((r) => r.bill_id),
    ).toEqual(["d"]);
  });

  it("paid matches settlement_status paid", () => {
    expect(
      rows.filter((r) => matchesBillFilter(r, "paid")).map((r) => r.bill_id),
    ).toEqual(["e"]);
  });

  it("closed matches cancelled and void", () => {
    expect(
      rows.filter((r) => matchesBillFilter(r, "closed")).map((r) => r.bill_id),
    ).toEqual(["f", "g"]);
  });

  it("filterBillRows combines filter and query", () => {
    const withNames = [
      row({ bill_id: "x", vendor_name: "PT Alpha", status: "approved" }),
      row({ bill_id: "y", vendor_name: "CV Beta", status: "draft" }),
    ];
    expect(filterBillRows(withNames, "open", "")).toEqual([withNames[0]]);
    expect(filterBillRows(withNames, null, "beta")).toEqual([withNames[1]]);
  });
});

describe("parseBillFilter", () => {
  it("accepts a known value and rejects unknown/absent ones", () => {
    expect(parseBillFilter("overdue")).toBe("overdue");
    expect(parseBillFilter("bogus")).toBeUndefined();
    expect(parseBillFilter(undefined)).toBeUndefined();
  });
});

describe("matchesBillQuery", () => {
  it("matches case-insensitively on vendor name or bill number", () => {
    const r = row({
      vendor_name: "CV Pemasok Utama",
      bill_number: "BILL-2026-0099",
    });
    expect(matchesBillQuery(r, "pemasok")).toBe(true);
    expect(matchesBillQuery(r, "0099")).toBe(true);
    expect(matchesBillQuery(r, "tidak-ada")).toBe(false);
  });

  it("matches a null bill_number bill by vendor name", () => {
    expect(
      matchesBillQuery(
        row({ bill_number: null, vendor_name: "CV Draf" }),
        "draf",
      ),
    ).toBe(true);
  });
});

describe("billActivityTimeline", () => {
  const base = {
    status: "draft" as const,
    submitted_at: null,
    rejected_at: null,
    reject_reason: null,
    approved_at: null,
    closed_at: null,
    closed_reason: null,
  };

  it("always starts with a draft-created entry", () => {
    expect(billActivityTimeline(base)).toEqual([
      { label: "Draf dibuat", date: null, tone: "neutral" },
    ]);
  });

  it("appends submitted, rejected, approved and closed entries in that order when present", () => {
    const timeline = billActivityTimeline({
      ...base,
      status: "void",
      submitted_at: "2026-09-01T00:00:00Z",
      approved_at: "2026-09-02T00:00:00Z",
      closed_at: "2026-09-10T00:00:00Z",
      closed_reason: "Salah vendor",
    });
    expect(timeline.map((e) => e.label)).toEqual([
      "Draf dibuat",
      "Diajukan untuk persetujuan",
      "Disetujui",
      "Dibatalkan (void): Salah vendor",
    ]);
  });

  it("includes the rejection reason when rejected", () => {
    const timeline = billActivityTimeline({
      ...base,
      submitted_at: "2026-09-01T00:00:00Z",
      rejected_at: "2026-09-02T00:00:00Z",
      reject_reason: "Jumlah tidak sesuai",
    });
    expect(timeline.at(-1)).toEqual({
      label: "Ditolak: Jumlah tidak sesuai",
      date: "2026-09-02T00:00:00Z",
      tone: "critical",
    });
  });

  it("labels a cancelled (not void) close distinctly", () => {
    const timeline = billActivityTimeline({
      ...base,
      status: "cancelled",
      closed_at: "2026-09-03T00:00:00Z",
      closed_reason: null,
    });
    expect(timeline.at(-1)).toEqual({
      label: "Dibatalkan",
      date: "2026-09-03T00:00:00Z",
      tone: "neutral",
    });
  });
});
