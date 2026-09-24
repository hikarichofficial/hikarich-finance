import { describe, expect, it } from "vitest";
import {
  entryTypeLabel,
  filterJournalRows,
  journalActivityTimeline,
  journalLineTotals,
  journalListStatus,
  journalSourceHref,
  matchesEntryType,
  matchesJournalQuery,
  matchesJournalStatus,
  matchesPeriod,
  mergeJournalLines,
  parseJournalFilter,
  parseJournalStatusFilter,
  periodLabel,
} from "./journalList";
import type { JournalEntryRow, JournalLineRow, LedgerAccountRow } from "@/schemas/accounting";

function row(overrides: Partial<JournalEntryRow> = {}): JournalEntryRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    journal_number: "JRN-2026-0001",
    entry_date: "2026-09-01",
    period_id: "22222222-2222-2222-2222-222222222222",
    status: "posted",
    entry_type: "manual",
    description: "Jurnal penyesuaian sewa",
    source_type: null,
    source_id: null,
    posting_key: null,
    reverses_journal_id: null,
    control_override_reason: null,
    posted_at: "2026-09-01T03:00:00.000Z",
    created_at: "2026-09-01T02:00:00.000Z",
    version: 1,
    ...overrides,
  };
}

describe("journalListStatus", () => {
  it("posted is success", () => {
    expect(journalListStatus(row({ status: "posted" }))).toEqual({
      text: "Terposting",
      tone: "success",
    });
  });

  it("draft is attention", () => {
    expect(journalListStatus(row({ status: "draft" }))).toEqual({
      text: "Draf",
      tone: "attention",
    });
  });
});

describe("entryTypeLabel", () => {
  it("humanizes every entry_type value", () => {
    expect(entryTypeLabel("system")).toBe("Sistem");
    expect(entryTypeLabel("manual")).toBe("Manual");
    expect(entryTypeLabel("adjusting")).toBe("Penyesuaian");
    expect(entryTypeLabel("reversal")).toBe("Pembalik");
    expect(entryTypeLabel("opening")).toBe("Saldo Awal");
    expect(entryTypeLabel("closing")).toBe("Penutupan");
  });
});

describe("matchesEntryType / parseJournalFilter", () => {
  it("null matches every entry_type", () => {
    expect(matchesEntryType(row({ entry_type: "system" }), null)).toBe(true);
    expect(matchesEntryType(row({ entry_type: "opening" }), null)).toBe(true);
  });

  it("a specific value matches only that entry_type", () => {
    expect(matchesEntryType(row({ entry_type: "manual" }), "manual")).toBe(true);
    expect(matchesEntryType(row({ entry_type: "system" }), "manual")).toBe(false);
  });

  it("parseJournalFilter accepts a known value and rejects everything else", () => {
    expect(parseJournalFilter("adjusting")).toBe("adjusting");
    expect(parseJournalFilter("bogus")).toBeUndefined();
    expect(parseJournalFilter(undefined)).toBeUndefined();
  });
});

describe("matchesJournalStatus / parseJournalStatusFilter", () => {
  it("null matches both statuses", () => {
    expect(matchesJournalStatus(row({ status: "draft" }), null)).toBe(true);
    expect(matchesJournalStatus(row({ status: "posted" }), null)).toBe(true);
  });

  it("a specific status matches only that status", () => {
    expect(matchesJournalStatus(row({ status: "draft" }), "posted")).toBe(false);
  });

  it("parseJournalStatusFilter accepts draft/posted only", () => {
    expect(parseJournalStatusFilter("draft")).toBe("draft");
    expect(parseJournalStatusFilter("posted")).toBe("posted");
    expect(parseJournalStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesPeriod", () => {
  it("null matches every period", () => {
    expect(matchesPeriod(row({ period_id: "x" }), null)).toBe(true);
  });

  it("a specific period id matches only that period", () => {
    expect(matchesPeriod(row({ period_id: "x" }), "x")).toBe(true);
    expect(matchesPeriod(row({ period_id: "x" }), "y")).toBe(false);
  });
});

describe("matchesJournalQuery", () => {
  it("matches the journal number, description or posting key", () => {
    expect(matchesJournalQuery(row({ journal_number: "JRN-2026-0099" }), "0099")).toBe(true);
    expect(matchesJournalQuery(row({ description: "Bayar sewa kantor" }), "sewa")).toBe(true);
    expect(matchesJournalQuery(row({ posting_key: "invoice.issue" }), "invoice.issue")).toBe(true);
    expect(matchesJournalQuery(row(), "tidak-ada")).toBe(false);
  });

  it("a null journal_number never matches a number query", () => {
    expect(matchesJournalQuery(row({ journal_number: null }), "jrn")).toBe(false);
  });
});

describe("filterJournalRows", () => {
  it("combines entry_type, status, period and query filters", () => {
    const rows = [
      row({ id: "x", entry_type: "manual", status: "draft", period_id: "p1", description: "sewa" }),
      row({
        id: "y",
        entry_type: "system",
        status: "posted",
        period_id: "p2",
        description: "invoice",
      }),
    ];
    expect(filterJournalRows(rows, "manual", null, null, "").map((r) => r.id)).toEqual(["x"]);
    expect(filterJournalRows(rows, null, "posted", null, "").map((r) => r.id)).toEqual(["y"]);
    expect(filterJournalRows(rows, null, null, "p1", "").map((r) => r.id)).toEqual(["x"]);
    expect(filterJournalRows(rows, null, null, null, "invoice").map((r) => r.id)).toEqual(["y"]);
  });
});

describe("journalSourceHref", () => {
  it("links the source types with an existing Detail screen", () => {
    expect(journalSourceHref("invoice", "inv-1", undefined)).toBe("/sales/invoices/inv-1");
    expect(journalSourceHref("bill", "bill-1", undefined)).toBe("/purchases/bills/bill-1");
    expect(journalSourceHref("transfer", "tr-1", undefined)).toBe("/money/transfers/tr-1");
  });

  it("carries the active Entity through as a query string", () => {
    expect(journalSourceHref("invoice", "inv-1", "acme")).toBe("/sales/invoices/inv-1?entity=acme");
  });

  it("returns null for a source type with no Detail screen yet, or a missing source", () => {
    expect(journalSourceHref("vendor_payment", "vp-1", undefined)).toBeNull();
    expect(journalSourceHref(null, null, undefined)).toBeNull();
  });
});

describe("periodLabel", () => {
  it("formats a period's month and year in Indonesian", () => {
    expect(periodLabel({ period_start: "2026-09-01" })).toBe("September 2026");
  });
});

describe("journalActivityTimeline", () => {
  it("always includes draft creation, and posting only when posted_at is set", () => {
    const draft = journalActivityTimeline(row({ posted_at: null }), null, undefined);
    expect(draft.map((e) => e.label)).toEqual(["Draf dibuat"]);

    const posted = journalActivityTimeline(row(), null, undefined);
    expect(posted.map((e) => e.label)).toEqual(["Draf dibuat", "Diposting"]);
  });

  it("links backward to the original when this journal reverses one", () => {
    const entries = journalActivityTimeline(
      row({ reverses_journal_id: "33333333-3333-3333-3333-333333333333" }),
      null,
      "acme",
    );
    const link = entries.find((e) => e.label === "Membalik jurnal lain");
    expect(link?.href).toBe("/accounting/journal/33333333-3333-3333-3333-333333333333?entity=acme");
  });

  it("links forward to the reversal when this journal has been reversed", () => {
    const entries = journalActivityTimeline(
      row(),
      { id: "44444444-4444-4444-4444-444444444444", journal_number: "JRN-2026-0007" },
      undefined,
    );
    const link = entries.find((e) => e.label === "Dibalik oleh JRN-2026-0007");
    expect(link?.href).toBe("/accounting/journal/44444444-4444-4444-4444-444444444444");
  });
});

function line(overrides: Partial<JournalLineRow> = {}): JournalLineRow {
  return {
    id: "55555555-5555-5555-5555-555555555555",
    journal_id: "11111111-1111-1111-1111-111111111111",
    line_no: 1,
    ledger_account_id: "66666666-6666-6666-6666-666666666666",
    debit: "100000",
    credit: "0",
    description: null,
    original_currency: null,
    original_amount: null,
    exchange_rate: null,
    ...overrides,
  };
}

function account(overrides: Partial<LedgerAccountRow> = {}): LedgerAccountRow {
  return {
    id: "66666666-6666-6666-6666-666666666666",
    entity_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    code: "1-1000",
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

describe("mergeJournalLines", () => {
  it("attaches the matching account's code and name to each line", () => {
    const merged = mergeJournalLines(
      [line({ ledger_account_id: "66666666-6666-6666-6666-666666666666" })],
      [account({ id: "66666666-6666-6666-6666-666666666666", code: "1-1000", name: "Kas" })],
    );
    expect(merged).toEqual([
      {
        line: line({ ledger_account_id: "66666666-6666-6666-6666-666666666666" }),
        accountCode: "1-1000",
        accountName: "Kas",
      },
    ]);
  });

  it("falls back to a placeholder when the account cannot be found", () => {
    const merged = mergeJournalLines([line({ ledger_account_id: "missing" })], []);
    expect(merged[0]).toMatchObject({ accountCode: "—", accountName: "Akun tidak dikenal" });
  });
});

describe("journalLineTotals", () => {
  it("sums debit and credit separately", () => {
    expect(
      journalLineTotals([
        line({ debit: "100000", credit: "0" }),
        line({ debit: "0", credit: "60000" }),
        line({ debit: "0", credit: "40000" }),
      ]),
    ).toEqual({ debit: 100000, credit: 100000 });
  });

  it("returns zero totals for no lines", () => {
    expect(journalLineTotals([])).toEqual({ debit: 0, credit: 0 });
  });
});
