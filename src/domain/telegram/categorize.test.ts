import { describe, expect, it } from "vitest";
import {
  type CategoryOption,
  looksLikeAsset,
  matchCategoryByName,
  suggestCategories,
} from "./categorize";

const cats: CategoryOption[] = [
  { id: "food", name: "Makan & Minum", kind: "expense", isParent: false },
  { id: "trans", name: "Transportasi", kind: "expense", isParent: false },
  { id: "soft", name: "Software & Langganan", kind: "expense", isParent: false },
  { id: "other", name: "Lainnya", kind: "expense", isParent: false },
  { id: "elec", name: "Elektronik", kind: "asset", isParent: false },
];

describe("suggestCategories", () => {
  it("uses everyday vocabulary", () => {
    expect(suggestCategories("makan siang di warteg", "expense", cats, [])[0]?.id).toBe("food");
    expect(suggestCategories("grab ke kantor", "expense", cats, [])[0]?.id).toBe("trans");
    expect(suggestCategories("langganan canva", "expense", cats, [])[0]?.id).toBe("soft");
  });
  it("prefers what the owner taught", () => {
    const rules = [
      { keyword: "warteg", categoryId: "other", accountId: null, payeeName: null, hits: 2 },
    ];
    const [best] = suggestCategories("makan di warteg", "expense", cats, rules);
    expect(best?.id).toBe("other");
    expect(best?.confidence).toBe("high");
  });
  it("falls back to 'Lainnya' with low confidence", () => {
    const [best] = suggestCategories("xyzzy", "expense", cats, []);
    expect(best).toMatchObject({ id: "other", confidence: "low" });
  });
  it("suggests asset categories for assets only", () => {
    expect(suggestCategories("iphone 15", "asset", cats, [])[0]?.id).toBe("elec");
    expect(suggestCategories("iphone 15", "expense", cats, []).every((s) => s.id !== "elec")).toBe(
      true,
    );
  });
});

describe("looksLikeAsset / matchCategoryByName", () => {
  it("spots durable items", () => {
    expect(looksLikeAsset("beli iPhone")).toBe(true);
    expect(looksLikeAsset("makan siang")).toBe(false);
  });
  it("matches typed names", () => {
    expect(matchCategoryByName("transport", cats, "expense")?.id).toBe("trans");
    expect(matchCategoryByName("langganan", cats, "expense")?.id).toBe("soft");
    expect(matchCategoryByName("zz", cats, "expense")).toBeNull();
  });
});
