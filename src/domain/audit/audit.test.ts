import { describe, expect, it } from "vitest";
import {
  AUDIT_OPERATION_FILTER_OPTIONS,
  AUDIT_PAGE_SIZE,
  auditOperationOf,
  changedFieldNames,
  parseAuditOffset,
  parseAuditOperation,
  shortId,
} from "./audit";

describe("parseAuditOperation", () => {
  it("accepts the three operations and rejects anything else", () => {
    expect(parseAuditOperation("insert")).toBe("insert");
    expect(parseAuditOperation("update")).toBe("update");
    expect(parseAuditOperation("delete")).toBe("delete");
    expect(parseAuditOperation("truncate")).toBeUndefined();
    expect(parseAuditOperation("toString")).toBeUndefined();
    expect(parseAuditOperation(undefined)).toBeUndefined();
  });
});

describe("parseAuditOffset", () => {
  it("accepts non-negative multiples of the page size", () => {
    expect(parseAuditOffset(undefined)).toBe(0);
    expect(parseAuditOffset("0")).toBe(0);
    expect(parseAuditOffset(String(AUDIT_PAGE_SIZE * 2))).toBe(AUDIT_PAGE_SIZE * 2);
  });

  it("falls back to the first page for anything else", () => {
    expect(parseAuditOffset("-50")).toBe(0);
    expect(parseAuditOffset("7")).toBe(0);
    expect(parseAuditOffset("abc")).toBe(0);
    expect(parseAuditOffset("1e3")).toBe(0);
    expect(parseAuditOffset("99999999999999999999")).toBe(0);
  });
});

describe("auditOperationOf", () => {
  it("reads the operation from <table>.<op>", () => {
    expect(auditOperationOf("invoices.insert")).toBe("insert");
    expect(auditOperationOf("journal_entries.update")).toBe("update");
    expect(auditOperationOf("contacts.delete")).toBe("delete");
  });

  it("returns undefined for any other shape", () => {
    expect(auditOperationOf("invoices.approve")).toBeUndefined();
    expect(auditOperationOf("")).toBeUndefined();
  });
});

describe("changedFieldNames", () => {
  it("lists differing fields, sorted, without bookkeeping columns", () => {
    expect(
      changedFieldNames(
        { status: "draft", memo: "a", version: 1, updated_at: "x", total: "1.00" },
        { status: "posted", memo: "a", version: 2, updated_at: "y", total: "2.00" },
      ),
    ).toEqual(["status", "total"]);
  });

  it("counts a field added or removed as changed", () => {
    expect(changedFieldNames({ a: 1 }, { a: 1, b: 2 })).toEqual(["b"]);
    expect(changedFieldNames({ a: 1, b: 2 }, { a: 1 })).toEqual(["b"]);
  });

  it("compares nested values structurally", () => {
    expect(changedFieldNames({ meta: { x: 1 } }, { meta: { x: 1 } })).toEqual([]);
    expect(changedFieldNames({ meta: { x: 1 } }, { meta: { x: 2 } })).toEqual(["meta"]);
  });

  it("lists nothing for an insert or delete", () => {
    expect(changedFieldNames(null, { a: 1 })).toEqual([]);
    expect(changedFieldNames({ a: 1 }, null)).toEqual([]);
  });
});

describe("filter options and shortId", () => {
  it("starts with an unfiltered tab", () => {
    expect(AUDIT_OPERATION_FILTER_OPTIONS.map((o) => o.value)).toEqual([
      undefined,
      "insert",
      "update",
      "delete",
    ]);
  });

  it("shortens a uuid to 8 characters", () => {
    expect(shortId("0f8fad5b-d9cb-469f-a165-70867728950e")).toBe("0f8fad5b");
  });
});
