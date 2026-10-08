import { describe, expect, it } from "vitest";
import { searchTargetTypeSchema } from "@/schemas/search";
import { documentTargetTypeSchema, genericLinkableTargetTypeSchema } from "@/schemas/documents";
import { SEARCH_TARGET_TYPE_LABELS } from "./search";

describe("SEARCH_TARGET_TYPE_LABELS", () => {
  it("has a label for every indexed target kind", () => {
    expect(Object.keys(SEARCH_TARGET_TYPE_LABELS).sort()).toEqual(
      [...searchTargetTypeSchema.options].sort(),
    );
  });

  it("covers the generic-linker document kinds minus import_batch (DECISIONS 145), plus products (SKU generator)", () => {
    const expected = [
      // income_entry takes documents (DECISIONS 350) but is not part of the search index.
      ...genericLinkableTargetTypeSchema.options.filter(
        (kind) => kind !== "import_batch" && kind !== "income_entry",
      ),
      "product",
    ].sort();
    expect([...searchTargetTypeSchema.options].sort()).toEqual(expected);
  });

  it("never indexes payroll or tax (decisions 131/145)", () => {
    expect(searchTargetTypeSchema.options).not.toContain("tax_filing");
    expect(searchTargetTypeSchema.options).not.toContain("tax_payment");
    expect(searchTargetTypeSchema.options).not.toContain("payroll_run");
  });

  it("every search target kind except products is a known document target kind", () => {
    for (const kind of searchTargetTypeSchema.options.filter((k) => k !== "product")) {
      expect(documentTargetTypeSchema.options).toContain(kind);
    }
  });
});
