import { describe, expect, it } from "vitest";
import {
  filterTaxLedgerRows,
  formatTaxRate,
  matchesTaxFamily,
  matchesTaxLedgerQuery,
  matchesTaxPeriod,
  matchesTaxSource,
  matchesTaxStatus,
  parseTaxFamilyFilter,
  parseTaxSourceFilter,
  parseTaxStatusFilter,
  taxDeterminationHref,
  taxKindLabel,
  taxLedgerPeriodOptions,
  taxLedgerStatus,
  taxSourceDocumentHref,
  taxTypeLabel,
} from "./taxLedgerList";
import type { TaxLedgerRow } from "@/schemas/tax";

function row(overrides: Partial<TaxLedgerRow> = {}): TaxLedgerRow {
  return {
    entry_id: "11111111-1111-1111-1111-111111111111",
    entry_date: "2026-09-15",
    tax_period: "2026-09-01",
    tax_kind: "vat_output",
    tax_type: "vat",
    direction: "payable",
    entry_kind: "accrual",
    amount: "1100000",
    source_type: "invoice",
    source_id: "22222222-2222-2222-2222-222222222222",
    determination_status: "auto_determined",
    journal_id: "33333333-3333-3333-3333-333333333333",
    description: "PPN keluaran INV-2026-0001",
    ...overrides,
  };
}

describe("taxLedgerStatus", () => {
  it("labels and tones a known determination status", () => {
    expect(taxLedgerStatus("auto_determined")).toEqual({
      text: "Ditentukan otomatis",
      tone: "progress",
    });
    expect(taxLedgerStatus("owner_confirmed").tone).toBe("success");
    expect(taxLedgerStatus("overridden").tone).toBe("attention");
    expect(taxLedgerStatus("superseded").tone).toBe("neutral");
  });

  it("shows unrecognised text as itself, neutral, rather than throwing", () => {
    expect(taxLedgerStatus("something_new")).toEqual({ text: "something_new", tone: "neutral" });
  });
});

describe("matchesTaxFamily / matchesTaxSource / matchesTaxStatus / matchesTaxPeriod", () => {
  const r = row();

  it("matches null as no filter", () => {
    expect(matchesTaxFamily(r, null)).toBe(true);
    expect(matchesTaxSource(r, null)).toBe(true);
    expect(matchesTaxStatus(r, null)).toBe(true);
    expect(matchesTaxPeriod(r, null)).toBe(true);
  });

  it("matches an exact value and rejects a different one", () => {
    expect(matchesTaxFamily(r, "vat")).toBe(true);
    expect(matchesTaxFamily(r, "wht_pph23")).toBe(false);
    expect(matchesTaxSource(r, "invoice")).toBe(true);
    expect(matchesTaxSource(r, "bill")).toBe(false);
    expect(matchesTaxStatus(r, "auto_determined")).toBe(true);
    expect(matchesTaxStatus(r, "overridden")).toBe(false);
    expect(matchesTaxPeriod(r, "2026-09-01")).toBe(true);
    expect(matchesTaxPeriod(r, "2026-08-01")).toBe(false);
  });
});

describe("matchesTaxLedgerQuery", () => {
  it("matches the description case-insensitively", () => {
    expect(matchesTaxLedgerQuery(row(), "ppn keluaran")).toBe(true);
    expect(matchesTaxLedgerQuery(row(), "tidak ada")).toBe(false);
  });

  it("treats an empty query as matching everything, and a null description as never matching a non-empty one", () => {
    expect(matchesTaxLedgerQuery(row({ description: null }), "")).toBe(true);
    expect(matchesTaxLedgerQuery(row({ description: null }), "ppn")).toBe(false);
  });
});

describe("filterTaxLedgerRows", () => {
  it("applies every predicate together", () => {
    const rows = [
      row({ entry_id: "1", tax_type: "vat", source_type: "invoice", tax_period: "2026-09-01" }),
      row({ entry_id: "2", tax_type: "wht_pph23", source_type: "bill", tax_period: "2026-09-01" }),
      row({ entry_id: "3", tax_type: "vat", source_type: "invoice", tax_period: "2026-08-01" }),
    ];
    const result = filterTaxLedgerRows(rows, "vat", "invoice", null, "2026-09-01", "");
    expect(result.map((r) => r.entry_id)).toEqual(["1"]);
  });
});

describe("parseTaxFamilyFilter / parseTaxSourceFilter / parseTaxStatusFilter", () => {
  it("accepts a listed value and rejects anything else", () => {
    expect(parseTaxFamilyFilter("vat")).toBe("vat");
    expect(parseTaxFamilyFilter("not_a_type")).toBeUndefined();
    expect(parseTaxSourceFilter("bill")).toBe("bill");
    expect(parseTaxSourceFilter("nope")).toBeUndefined();
    expect(parseTaxStatusFilter("overridden")).toBe("overridden");
    expect(parseTaxStatusFilter("needs_review")).toBeUndefined();
  });
});

describe("taxLedgerPeriodOptions", () => {
  it("lists each distinct period once, newest first, with an Indonesian label", () => {
    const rows = [
      row({ tax_period: "2026-08-01" }),
      row({ tax_period: "2026-09-01" }),
      row({ tax_period: "2026-08-01" }),
    ];
    expect(taxLedgerPeriodOptions(rows)).toEqual([
      { value: "2026-09-01", label: "September 2026" },
      { value: "2026-08-01", label: "Agustus 2026" },
    ]);
  });
});

describe("taxDeterminationHref", () => {
  it("links a document source, with the entity query string when given", () => {
    expect(taxDeterminationHref("invoice", "abc", "hikarich")).toBe(
      "/tax/determination/invoice/abc?entity=hikarich",
    );
    expect(taxDeterminationHref("bill", "abc", undefined)).toBe("/tax/determination/bill/abc");
  });

  it("never links a period determination or a missing source id", () => {
    expect(taxDeterminationHref("period", null, "hikarich")).toBeNull();
    expect(taxDeterminationHref("invoice", null, "hikarich")).toBeNull();
  });
});

describe("taxSourceDocumentHref", () => {
  it("links invoice and bill, and leaves expense unlinked", () => {
    expect(taxSourceDocumentHref("invoice", "abc", undefined)).toBe("/sales/invoices/abc");
    expect(taxSourceDocumentHref("bill", "abc", "hikarich")).toBe(
      "/purchases/bills/abc?entity=hikarich",
    );
    expect(taxSourceDocumentHref("expense", "abc", undefined)).toBeNull();
  });
});

describe("taxKindLabel / taxTypeLabel", () => {
  it("labels in Indonesian", () => {
    expect(taxKindLabel("vat_output")).toBe("PPN keluaran");
    expect(taxTypeLabel("wht_pph23")).toBe("PPh 23 (dipotong)");
  });
});

describe("formatTaxRate", () => {
  it("shows a fraction as a percentage without trailing zeros", () => {
    expect(formatTaxRate("0.11")).toBe("11%");
    expect(formatTaxRate("0.02")).toBe("2%");
    expect(formatTaxRate("0.005")).toBe("0,5%");
  });

  it("shows a dash when there is no single rate", () => {
    expect(formatTaxRate(null)).toBe("—");
  });
});
