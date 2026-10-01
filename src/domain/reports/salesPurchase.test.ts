import { describe, expect, it } from "vitest";
import {
  dimensionOptions,
  parseDimension,
  parseSide,
  reportQueryToSave,
  salesPurchaseTotals,
  savedReportHref,
} from "./salesPurchase";

describe("filters", () => {
  it("defaults to sales by party", () => {
    expect(parseSide(undefined)).toBe("sales");
    expect(parseSide("purchases")).toBe("purchases");
    expect(parseDimension(undefined, "sales")).toBe("party");
  });

  it("offers product only for sales", () => {
    expect(dimensionOptions("sales")).toContain("product");
    expect(dimensionOptions("purchases")).not.toContain("product");
    expect(parseDimension("product", "purchases")).toBe("party");
    expect(parseDimension("month", "purchases")).toBe("month");
  });
});

describe("salesPurchaseTotals", () => {
  it("sums exactly", () => {
    expect(
      salesPurchaseTotals([
        {
          dimension_id: null,
          dimension_label: "A",
          period_month: null,
          document_count: 2,
          net_amount: "1000000.10",
          gross_amount: "1110000.11",
        },
        {
          dimension_id: null,
          dimension_label: "B",
          period_month: null,
          document_count: 1,
          net_amount: "0.20",
          gross_amount: "0.22",
        },
      ]),
    ).toEqual({ documents: 3, net: "1000000.30", gross: "1110000.33" });
  });
});

describe("saved report links", () => {
  it("saves every filter except the Entity", () => {
    expect(
      reportQueryToSave({
        entity: "hkr",
        statement: "pnl",
        from: "2026-01-01",
        to: "",
        entities: ["a", "b"],
      }),
    ).toBe("statement=pnl&from=2026-01-01&entities=a&entities=b");
  });

  it("opens in the active Entity", () => {
    expect(savedReportHref({ report_path: "/reports", report_query: "statement=pnl" }, "hkr")).toBe(
      "/reports?statement=pnl&entity=hkr",
    );
    expect(
      savedReportHref({ report_path: "/reports/sales-purchase", report_query: "" }, undefined),
    ).toBe("/reports/sales-purchase");
  });
});
