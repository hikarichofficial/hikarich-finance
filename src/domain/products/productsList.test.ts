import { describe, expect, it } from "vitest";
import { productInputSchema, type ProductRow } from "@/schemas/products";
import { filterProducts, parseProductFilter } from "./productsList";

function row(overrides: Partial<ProductRow>): ProductRow {
  return {
    id: "0f8fad5b-d9cb-469f-a165-70867728950e",
    entity_id: "7c9e6679-7425-40de-944b-e07fc1f90ae7",
    kind: "product",
    sku: null,
    name: "Produk",
    description: null,
    unit: "unit",
    default_unit_price: null,
    default_currency: null,
    default_category_id: null,
    is_active: true,
    version: 1,
    ...overrides,
  };
}

describe("parseProductFilter", () => {
  it("accepts known filters only", () => {
    expect(parseProductFilter("active")).toBe("active");
    expect(parseProductFilter("service")).toBe("service");
    expect(parseProductFilter("toString")).toBeUndefined();
    expect(parseProductFilter(undefined)).toBeUndefined();
  });
});

describe("filterProducts", () => {
  const rows = [
    row({ name: "Desain Logo", kind: "service", sku: "SVC-01" }),
    row({ name: "Kaos", kind: "product", is_active: false }),
    row({ name: "Stiker", kind: "product", description: "vinyl" }),
  ];

  it("filters by status and kind", () => {
    expect(filterProducts(rows, "inactive", "").map((r) => r.name)).toEqual(["Kaos"]);
    expect(filterProducts(rows, "service", "").map((r) => r.name)).toEqual(["Desain Logo"]);
    expect(filterProducts(rows, "active", "").map((r) => r.name)).toEqual([
      "Desain Logo",
      "Stiker",
    ]);
  });

  it("searches name, sku and description case-insensitively", () => {
    expect(filterProducts(rows, undefined, "svc").map((r) => r.name)).toEqual(["Desain Logo"]);
    expect(filterProducts(rows, undefined, "VINYL").map((r) => r.name)).toEqual(["Stiker"]);
  });
});

describe("productInputSchema", () => {
  it("turns empty optional fields into null", () => {
    const parsed = productInputSchema.parse({
      kind: "service",
      name: " Konsultasi ",
      sku: "",
      description: "",
      unit: "jam",
      default_unit_price: "",
      default_currency: "",
      default_category_id: "",
      is_active: true,
    });
    expect(parsed).toMatchObject({
      name: "Konsultasi",
      sku: null,
      description: null,
      default_unit_price: null,
      default_currency: null,
      default_category_id: null,
    });
  });

  it("rejects an invalid price or currency", () => {
    const base = {
      kind: "product",
      name: "X",
      sku: "",
      description: "",
      unit: "unit",
      default_category_id: "",
      is_active: true,
    };
    expect(
      productInputSchema.safeParse({ ...base, default_unit_price: "1,5", default_currency: "" })
        .success,
    ).toBe(false);
    expect(
      productInputSchema.safeParse({ ...base, default_unit_price: "", default_currency: "idr" })
        .success,
    ).toBe(false);
  });
});
