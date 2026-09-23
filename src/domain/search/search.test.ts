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

  it("covers exactly the generic-linker document kinds minus import_batch (DECISIONS 145)", () => {
    const expected = genericLinkableTargetTypeSchema.options
      .filter((kind) => kind !== "import_batch")
      .sort();
    expect([...searchTargetTypeSchema.options].sort()).toEqual(expected);
  });

  it("never indexes payroll or tax (decisions 131/145)", () => {
    expect(searchTargetTypeSchema.options).not.toContain("tax_filing");
    expect(searchTargetTypeSchema.options).not.toContain("tax_payment");
    expect(searchTargetTypeSchema.options).not.toContain("payroll_run");
  });

  it("every search target kind is a known document target kind", () => {
    for (const kind of searchTargetTypeSchema.options) {
      expect(documentTargetTypeSchema.options).toContain(kind);
    }
  });
});
