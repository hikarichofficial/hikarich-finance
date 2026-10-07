import { describe, expect, it } from "vitest";
import { composeSku, describeSkuError, type SkuFormat } from "./sku";

const base: SkuFormat = {
  components: [
    { key: "brand", enabled: true, required: true },
    { key: "type", enabled: true, required: true },
    { key: "seq", enabled: true, required: true },
    { key: "variant", enabled: true, required: false },
  ],
  separator: "-",
  prefix: "",
  suffix: "",
  emptyHandling: "skip",
  emptyPlaceholder: "XX",
  digits: 3,
};
const v = { brand: "KEA", type: "EA", number: 1 };

describe("composeSku", () => {
  it("builds the default structure, with and without a variant", () => {
    expect(composeSku(base, v, { base: true })).toEqual({ sku: "KEA-EA-001" });
    expect(composeSku(base, { ...v, variant: "1B" })).toEqual({ sku: "KEA-EA-001-1B" });
  });

  it("follows order, separator, prefix, suffix and digits", () => {
    const reordered: SkuFormat = {
      ...base,
      components: [
        base.components[0]!,
        base.components[2]!,
        base.components[1]!,
        base.components[3]!,
      ],
      separator: "/",
      prefix: "HIK",
      digits: 4,
    };
    expect(composeSku(reordered, { ...v, variant: "1B" })).toEqual({ sku: "HIK/KEA/0001/EA/1B" });
    expect(composeSku({ ...base, suffix: "ID" }, v, { base: true })).toEqual({
      sku: "KEA-EA-001-ID",
    });
  });

  it("never leaves a double separator when a part is switched off or empty", () => {
    const noType: SkuFormat = {
      ...base,
      components: base.components.map((c) => (c.key === "type" ? { ...c, enabled: false } : c)),
    };
    expect(composeSku(noType, { ...v, variant: "1B" })).toEqual({ sku: "KEA-001-1B" });
    expect(composeSku(base, { ...v, variant: "" })).toEqual({ sku: "KEA-EA-001" });
  });

  it("can fill an empty part with a fixed filler instead", () => {
    expect(composeSku({ ...base, emptyHandling: "placeholder" }, v, { base: true })).toEqual({
      sku: "KEA-EA-001-XX",
    });
  });

  it("reports the required part that is missing", () => {
    expect(composeSku(base, { type: "EA", number: 1 })).toEqual({ error: "brand" });
    const needVariant: SkuFormat = {
      ...base,
      components: base.components.map((c) => (c.key === "variant" ? { ...c, required: true } : c)),
    };
    expect(composeSku(needVariant, v)).toEqual({ error: "variant" });
    expect(composeSku(needVariant, v, { base: true })).toEqual({ sku: "KEA-EA-001" });
  });
});

describe("describeSkuError", () => {
  it("explains the database's SKU refusals in plain Indonesian", () => {
    expect(describeSkuError("SKU_OVERRIDE_FORBIDDEN")).toMatch(/OWNER/);
    expect(describeSkuError("SKU_MASTER_IN_USE")).toMatch(/Arsipkan/);
    expect(
      describeSkuError(
        'duplicate key value violates unique constraint "product_brands_code_uq"',
        "23505",
      ),
    ).toMatch(/Kode/);
    expect(
      describeSkuError(
        'duplicate key value violates unique constraint "products_entity_sku_uq"',
        "23505",
      ),
    ).toMatch(/unik/);
  });
});
