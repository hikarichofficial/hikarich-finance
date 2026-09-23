import { describe, expect, it } from "vitest";
import { documentTargetTypeSchema, genericLinkableTargetTypeSchema } from "@/schemas/documents";
import {
  DOCUMENT_PURPOSE_LABELS,
  DOCUMENT_TARGET_TYPE_LABELS,
  formatDocumentSize,
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
