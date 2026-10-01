import { describe, expect, it } from "vitest";
import {
  importBatchStatusSchema,
  importDomainSchema,
  importRowStatusSchema,
  legacyOpenItemKindSchema,
  legacyOpenItemStatusSchema,
} from "@/schemas/imports";
import {
  IMPORT_BATCH_STATUS_LABELS,
  IMPORT_BATCH_STATUS_TONE,
  IMPORT_DOMAIN_FILTER_OPTIONS,
  IMPORT_ROW_STATUS_FILTER_OPTIONS,
  IMPORT_ROW_STATUS_TONE,
  parseImportDomainFilter,
  parseImportRowStatusFilter,
  IMPORT_DOMAIN_LABELS,
  IMPORT_ROW_STATUS_LABELS,
  LEGACY_OPEN_ITEM_KIND_LABELS,
  LEGACY_OPEN_ITEM_STATUS_LABELS,
  importBatchActions,
} from "./imports";

describe("label completeness", () => {
  it("has a label for every import domain", () => {
    expect(Object.keys(IMPORT_DOMAIN_LABELS).sort()).toEqual(
      [...importDomainSchema.options].sort(),
    );
  });

  it("has a label for every batch status", () => {
    expect(Object.keys(IMPORT_BATCH_STATUS_LABELS).sort()).toEqual(
      [...importBatchStatusSchema.options].sort(),
    );
  });

  it("has a label for every row status", () => {
    expect(Object.keys(IMPORT_ROW_STATUS_LABELS).sort()).toEqual(
      [...importRowStatusSchema.options].sort(),
    );
  });

  it("has a label for every legacy open item kind", () => {
    expect(Object.keys(LEGACY_OPEN_ITEM_KIND_LABELS).sort()).toEqual(
      [...legacyOpenItemKindSchema.options].sort(),
    );
  });

  it("has a label for every legacy open item status", () => {
    expect(Object.keys(LEGACY_OPEN_ITEM_STATUS_LABELS).sort()).toEqual(
      [...legacyOpenItemStatusSchema.options].sort(),
    );
  });
});

describe("importBatchActions", () => {
  it("a staging batch can be validated but not committed or rolled back", () => {
    expect(importBatchActions("staging")).toEqual({
      canValidate: true,
      canCommit: false,
      canRollback: false,
    });
  });

  it("a validated batch can be committed but not re-validated or rolled back", () => {
    expect(importBatchActions("validated")).toEqual({
      canValidate: false,
      canCommit: true,
      canRollback: false,
    });
  });

  it("a committed batch can only be rolled back", () => {
    expect(importBatchActions("committed")).toEqual({
      canValidate: false,
      canCommit: false,
      canRollback: true,
    });
  });

  it("a rolled-back batch offers no further action", () => {
    expect(importBatchActions("rolled_back")).toEqual({
      canValidate: false,
      canCommit: false,
      canRollback: false,
    });
  });
});

describe("import history screen helpers (decision 241)", () => {
  it("has a tone for every batch and row status", () => {
    for (const status of importBatchStatusSchema.options) {
      expect(IMPORT_BATCH_STATUS_TONE[status]).toBeDefined();
    }
    for (const status of importRowStatusSchema.options) {
      expect(IMPORT_ROW_STATUS_TONE[status]).toBeDefined();
    }
  });

  it("lists every domain and row status as a filter tab, after an unfiltered first tab", () => {
    expect(IMPORT_DOMAIN_FILTER_OPTIONS[0]).toEqual({ value: undefined, label: "Semua" });
    expect(IMPORT_DOMAIN_FILTER_OPTIONS.slice(1).map((o) => o.value)).toEqual(
      importDomainSchema.options,
    );
    expect(IMPORT_ROW_STATUS_FILTER_OPTIONS[0]).toEqual({ value: undefined, label: "Semua" });
    expect(IMPORT_ROW_STATUS_FILTER_OPTIONS.slice(1).map((o) => o.value)).toEqual(
      importRowStatusSchema.options,
    );
  });

  it("parses a known domain filter and falls back to unfiltered otherwise", () => {
    expect(parseImportDomainFilter("contacts")).toBe("contacts");
    expect(parseImportDomainFilter("bogus")).toBeUndefined();
    expect(parseImportDomainFilter("toString")).toBeUndefined();
    expect(parseImportDomainFilter(undefined)).toBeUndefined();
  });

  it("parses a known row status filter and falls back to unfiltered otherwise", () => {
    expect(parseImportRowStatusFilter("invalid")).toBe("invalid");
    expect(parseImportRowStatusFilter("bogus")).toBeUndefined();
    expect(parseImportRowStatusFilter("constructor")).toBeUndefined();
    expect(parseImportRowStatusFilter(undefined)).toBeUndefined();
  });
});
