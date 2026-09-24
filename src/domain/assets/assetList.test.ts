import { describe, expect, it } from "vitest";
import {
  assetConditionBadge,
  assetEventDisplay,
  assetStatusBadge,
  depreciationLineStatusBadge,
  filterAssetRows,
  matchesAssetQuery,
  parseAssetStatusFilter,
} from "./assetList";
import type { AssetRow } from "@/schemas/assets";

function row(overrides: Partial<AssetRow> = {}): AssetRow {
  return {
    asset_id: "11111111-1111-1111-1111-111111111111",
    asset_code: "FA-2026-0001",
    name: "Laptop Kantor",
    status: "active",
    condition: "in_use",
    location: "Kantor Pusat",
    custodian: "Budi",
    source_type: "bill_line",
    acquisition_date: "2026-01-10",
    in_service_date: "2026-01-15",
    acquisition_cost: "15000000",
    accumulated: "1250000",
    net_book_value: "13750000",
    depreciation_method: "straight_line",
    useful_life_months: 48,
    residual_value: "0",
    fiscal_class_key: "group_1",
    ...overrides,
  };
}

describe("assetStatusBadge / assetConditionBadge", () => {
  it("labels and tones every status", () => {
    expect(assetStatusBadge("active")).toEqual({ text: "Aktif", tone: "success" });
    expect(assetStatusBadge("cancelled").tone).toBe("critical");
    expect(assetStatusBadge("draft").tone).toBe("neutral");
  });

  it("labels and tones every condition", () => {
    expect(assetConditionBadge("in_use").tone).toBe("success");
    expect(assetConditionBadge("damaged").tone).toBe("critical");
    expect(assetConditionBadge("under_repair").tone).toBe("attention");
  });
});

describe("matchesAssetQuery / filterAssetRows", () => {
  it("matches the asset code or name, case-insensitively", () => {
    expect(matchesAssetQuery(row(), "fa-2026")).toBe(true);
    expect(matchesAssetQuery(row(), "laptop")).toBe(true);
    expect(matchesAssetQuery(row(), "tidak ada")).toBe(false);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesAssetQuery(row(), "")).toBe(true);
  });

  it("filters a list down to the matches", () => {
    const rows = [
      row({ asset_id: "1", name: "Laptop Kantor" }),
      row({ asset_id: "2", name: "Meja Kerja" }),
    ];
    expect(filterAssetRows(rows, "meja").map((r) => r.asset_id)).toEqual(["2"]);
  });
});

describe("parseAssetStatusFilter", () => {
  it("accepts a listed status and rejects anything else", () => {
    expect(parseAssetStatusFilter("active")).toBe("active");
    expect(parseAssetStatusFilter("not_a_status")).toBeUndefined();
  });
});

describe("assetEventDisplay", () => {
  it("labels a known lifecycle event", () => {
    expect(assetEventDisplay("activated")).toEqual({ text: "Diaktifkan", tone: "success" });
    expect(assetEventDisplay("disposed").tone).toBe("neutral");
  });

  it("shows unrecognised text as itself, neutral, rather than throwing", () => {
    expect(assetEventDisplay("something_new")).toEqual({ text: "something_new", tone: "neutral" });
  });
});

describe("depreciationLineStatusBadge", () => {
  it("labels and tones every schedule line status", () => {
    expect(depreciationLineStatusBadge("posted")).toEqual({ text: "Terposting", tone: "success" });
    expect(depreciationLineStatusBadge("reversed").tone).toBe("attention");
    expect(depreciationLineStatusBadge("cancelled").tone).toBe("critical");
    expect(depreciationLineStatusBadge("scheduled").tone).toBe("neutral");
  });
});
