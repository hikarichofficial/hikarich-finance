import { describe, expect, it } from "vitest";
import { documentTargetTypeSchema, genericLinkableTargetTypeSchema } from "@/schemas/documents";
import {
  DOCUMENT_PURPOSE_LABELS,
  DOCUMENT_TARGET_TYPE_FILTER_OPTIONS,
  DOCUMENT_TARGET_TYPE_LABELS,
  documentTargetTypesLabel,
  filterDocumentsByLinkStatus,
  formatDocumentSize,
  parseDocumentTargetTypeFilter,
} from "./documents";

describe("DOCUMENT_TARGET_TYPE_LABELS", () => {
  it("has a label for every catalogued target kind (DECISIONS 141/147)", () => {
    expect(Object.keys(DOCUMENT_TARGET_TYPE_LABELS).sort()).toEqual(
      [...documentTargetTypeSchema.options].sort(),
    );
  });

  it("every generic-linker kind is a subset of the full target type list", () => {
    for (const kind of genericLinkableTargetTypeSchema.options) {
      expect(documentTargetTypeSchema.options).toContain(kind);
    }
    // tax_filing/tax_payment keep their own dedicated linker and are never generic-linkable.
    expect(genericLinkableTargetTypeSchema.options).not.toContain("tax_filing");
    expect(genericLinkableTargetTypeSchema.options).not.toContain("tax_payment");
  });
});

describe("DOCUMENT_PURPOSE_LABELS", () => {
  it("has a label for every purpose", () => {
    expect(Object.keys(DOCUMENT_PURPOSE_LABELS).sort()).toEqual([
      "contract",
      "other",
      "receipt",
      "vendor_invoice",
    ]);
  });
});

describe("formatDocumentSize", () => {
  it("formats bytes below 1 KB as bytes", () => {
    expect(formatDocumentSize(512)).toBe("512 B");
  });

  it("formats kilobytes with no decimal at or above 10 KB", () => {
    expect(formatDocumentSize(20 * 1024)).toBe("20 KB");
  });

  it("formats kilobytes with one decimal below 10 KB", () => {
    expect(formatDocumentSize(1536)).toBe("1.5 KB");
  });

  it("formats megabytes with one decimal below 10 MB", () => {
    expect(formatDocumentSize(5 * 1024 * 1024)).toBe("5.0 MB");
  });

  it("formats megabytes with no decimal at or above 10 MB", () => {
    expect(formatDocumentSize(20 * 1024 * 1024)).toBe("20 MB");
  });
});

describe("DOCUMENT_TARGET_TYPE_FILTER_OPTIONS", () => {
  it("starts with the unfiltered 'Semua' option, then every catalogued target kind in schema order", () => {
    expect(DOCUMENT_TARGET_TYPE_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua" });
    expect(DOCUMENT_TARGET_TYPE_FILTER_OPTIONS.slice(1).map((o) => o.value)).toEqual([
      ...documentTargetTypeSchema.options,
    ]);
  });
});

describe("parseDocumentTargetTypeFilter", () => {
  it("resolves a known target kind", () => {
    expect(parseDocumentTargetTypeFilter("bill")).toBe("bill");
  });

  it("falls back to the unfiltered default (undefined) for an unknown value", () => {
    expect(parseDocumentTargetTypeFilter("not-a-kind")).toBeUndefined();
  });

  it("falls back to the unfiltered default (undefined) when nothing is requested", () => {
    expect(parseDocumentTargetTypeFilter(undefined)).toBeUndefined();
  });

  it("treats the literal 'null' query value as unknown, not as the unfiltered option", () => {
    // the unfiltered option's *value* is JS null, never the string "null" a query param could carry.
    expect(parseDocumentTargetTypeFilter("null")).toBeUndefined();
  });
});

describe("documentTargetTypesLabel", () => {
  it("joins multiple target kinds into one display string", () => {
    expect(documentTargetTypesLabel(["bill", "expense"])).toBe("Tagihan, Pengeluaran");
  });

  it("returns an em dash for a document with no links yet", () => {
    expect(documentTargetTypesLabel([])).toBe("—");
  });

  it("falls back to the raw value for an unrecognized kind rather than dropping it", () => {
    expect(documentTargetTypesLabel(["future_kind"])).toBe("future_kind");
  });
});

describe("filterDocumentsByLinkStatus", () => {
  const rows = [
    { id: "a", link_count: 0 },
    { id: "b", link_count: 2 },
    { id: "c", link_count: 0 },
    { id: "d", link_count: 1 },
  ];

  it("keeps only documents with no active link for 'unlinked'", () => {
    expect(filterDocumentsByLinkStatus(rows, "unlinked").map((r) => r.id)).toEqual(["a", "c"]);
  });

  it("keeps only documents with at least one active link for 'linked'", () => {
    expect(filterDocumentsByLinkStatus(rows, "linked").map((r) => r.id)).toEqual(["b", "d"]);
  });

  it("returns an empty array when nothing matches", () => {
    expect(filterDocumentsByLinkStatus([], "linked")).toEqual([]);
  });
});
