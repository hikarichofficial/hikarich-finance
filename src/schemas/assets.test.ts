import { describe, expect, it } from "vitest";
import {
  activateAssetInputSchema,
  assetDetailSchema,
  disposeAssetInputSchema,
  loadOpeningAssetsInputSchema,
  splitAssetInputSchema,
  transferAssetInputSchema,
} from "./assets";

const ASSET = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a01";
const ACCOUNT = "0b2f6d0e-6d2e-4a55-9c58-3f6f3c1d7a02";
const KEY = "key-asset-0001";

describe("activation", () => {
  const base = { asset_id: ASSET, idempotency_key: KEY, in_service_date: "2027-03-09" };

  it("a depreciated asset needs its life", () => {
    expect(activateAssetInputSchema.safeParse({ ...base, method: "straight_line" }).success).toBe(
      false,
    );
    expect(
      activateAssetInputSchema.safeParse({ ...base, method: "straight_line", life_months: 48 })
        .success,
    ).toBe(true);
  });

  it("an undepreciated asset (land) needs none", () => {
    expect(activateAssetInputSchema.safeParse({ ...base, method: "none" }).success).toBe(true);
  });

  it("refuses a life outside 1 to 1200 months, a fractional life and a malformed amount", () => {
    for (const life of [0, 1201, 12.5]) {
      expect(
        activateAssetInputSchema.safeParse({ ...base, method: "straight_line", life_months: life })
          .success,
      ).toBe(false);
    }
    expect(
      activateAssetInputSchema.safeParse({
        ...base,
        method: "straight_line",
        life_months: 12,
        residual: "1,000",
      }).success,
    ).toBe(false);
  });

  it("refuses a made-up depreciation method or an impossible date", () => {
    expect(
      activateAssetInputSchema.safeParse({ ...base, method: "sum_of_digits", life_months: 12 })
        .success,
    ).toBe(false);
    expect(
      activateAssetInputSchema.safeParse({ ...base, in_service_date: "2027-02-30", method: "none" })
        .success,
    ).toBe(false);
  });
});

describe("splitting", () => {
  it("needs 2 to 50 named parts with exact amounts", () => {
    const part = (name: string, cost: string) => ({ name, cost });
    const input = { asset_id: ASSET, idempotency_key: KEY };
    expect(
      splitAssetInputSchema.safeParse({ ...input, parts: [part("A", "7000000")] }).success,
    ).toBe(false);
    expect(
      splitAssetInputSchema.safeParse({
        ...input,
        parts: [part("A", "7000000"), part("B", "5000000")],
      }).success,
    ).toBe(true);
    expect(
      splitAssetInputSchema.safeParse({ ...input, parts: [part("A", "7e6"), part("B", "5000000")] })
        .success,
    ).toBe(false);
    expect(
      splitAssetInputSchema.safeParse({ ...input, parts: [part("", "1"), part("B", "1")] }).success,
    ).toBe(false);
  });
});

describe("transfer", () => {
  it("needs a new location or a new custodian", () => {
    const base = { asset_id: ASSET, date: "2027-03-09" };
    expect(transferAssetInputSchema.safeParse(base).success).toBe(false);
    expect(
      transferAssetInputSchema.safeParse({ ...base, location: "Kantor Bandung" }).success,
    ).toBe(true);
    expect(transferAssetInputSchema.safeParse({ ...base, custodian: "Sari" }).success).toBe(true);
  });
});

describe("disposal", () => {
  const base = {
    asset_id: ASSET,
    idempotency_key: KEY,
    date: "2027-09-01",
    reason: "Dijual karena diganti unit baru",
  };

  it("a sale for cash names the account that received the money", () => {
    expect(
      disposeAssetInputSchema.safeParse({
        ...base,
        type: "sale",
        proceeds: "5000000",
        proceeds_method: "cash",
      }).success,
    ).toBe(false);
    expect(
      disposeAssetInputSchema.safeParse({
        ...base,
        type: "sale",
        proceeds: "5000000",
        proceeds_method: "cash",
        account_id: ACCOUNT,
      }).success,
    ).toBe(true);
  });

  it("a sale on credit names who owes it", () => {
    expect(
      disposeAssetInputSchema.safeParse({
        ...base,
        type: "sale",
        proceeds: "5000000",
        proceeds_method: "receivable",
      }).success,
    ).toBe(false);
    expect(
      disposeAssetInputSchema.safeParse({
        ...base,
        type: "sale",
        proceeds: "5000000",
        proceeds_method: "receivable",
        counterparty: "CV Maju",
      }).success,
    ).toBe(true);
  });

  it("only a sale has proceeds; a scrap is written off with none", () => {
    expect(
      disposeAssetInputSchema.safeParse({
        ...base,
        type: "scrapped",
        proceeds: "1000",
        proceeds_method: "cash",
        account_id: ACCOUNT,
      }).success,
    ).toBe(false);
    const scrapped = disposeAssetInputSchema.safeParse({ ...base, type: "scrapped" });
    expect(scrapped.success).toBe(true);
    if (scrapped.success) {
      expect(scrapped.data.proceeds).toBe("0");
      expect(scrapped.data.proceeds_method).toBe("none");
    }
  });

  it("a reason is written down", () => {
    expect(
      disposeAssetInputSchema.safeParse({ ...base, reason: "x", type: "scrapped" }).success,
    ).toBe(false);
  });
});

describe("opening assets", () => {
  const asset = {
    name: "Laptop",
    cost_account: ACCOUNT,
    acquisition_date: "2026-01-10",
    in_service_date: "2026-01-10",
    cutover_date: "2026-08-31",
    cost: "12000000",
  };

  it("carries the cost, the accumulated depreciation and the plan forward", () => {
    const parsed = loadOpeningAssetsInputSchema.safeParse({
      entity_id: ASSET,
      idempotency_key: KEY,
      assets: [
        {
          ...asset,
          accumulated: "1750000",
          method: "straight_line",
          life_months: 48,
          residual: "0",
        },
      ],
    });
    expect(parsed.success).toBe(true);
  });

  it("refuses an empty load and a fractional-cent amount", () => {
    expect(
      loadOpeningAssetsInputSchema.safeParse({ entity_id: ASSET, idempotency_key: KEY, assets: [] })
        .success,
    ).toBe(false);
    expect(
      loadOpeningAssetsInputSchema.safeParse({
        entity_id: ASSET,
        idempotency_key: KEY,
        assets: [{ ...asset, cost: "1200.00001" }],
      }).success,
    ).toBe(false);
  });
});

describe("what the database returns", () => {
  it("refuses a detail that is not shaped like one", () => {
    expect(assetDetailSchema.safeParse({ asset: {} }).success).toBe(false);
  });
});
