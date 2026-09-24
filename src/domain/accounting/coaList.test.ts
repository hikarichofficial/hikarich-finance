import { describe, expect, it } from "vitest";
import {
  accountClassLabel,
  buildCoaTree,
  coaIndicators,
  coaVisibleIds,
  matchesCoaQuery,
  matchesCoaStatus,
  parseCoaStatusFilter,
} from "./coaList";
import type { LedgerAccountRow } from "@/schemas/accounting";

function account(overrides: Partial<LedgerAccountRow> = {}): LedgerAccountRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    entity_id: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
    code: "1000",
    name: "Kas",
    account_class: "asset",
    normal_balance: "debit",
    system_key: null,
    parent_id: null,
    is_group: false,
    is_control: false,
    allows_manual_posting: true,
    status: "active",
    ...overrides,
  };
}

describe("buildCoaTree", () => {
  const root = account({ id: "root", code: "1000", name: "Aset", is_group: true, parent_id: null });
  const child = account({
    id: "child",
    code: "1100",
    name: "Kas & Bank",
    is_group: true,
    parent_id: "root",
  });
  const leafA = account({ id: "leafA", code: "1101", name: "Kas Kecil", parent_id: "child" });
  const leafB = account({ id: "leafB", code: "1102", name: "Bank BCA", parent_id: "child" });
  const other = account({
    id: "other",
    code: "2000",
    name: "Liabilitas",
    is_group: true,
    parent_id: null,
  });
  const accounts = [other, leafB, root, leafA, child];

  it("flattens depth-first, ordered by code within each level, with no filter", () => {
    const tree = buildCoaTree(accounts);
    expect(tree.map((r) => [r.account.code, r.depth])).toEqual([
      ["1000", 0],
      ["1100", 1],
      ["1101", 2],
      ["1102", 2],
      ["2000", 0],
    ]);
  });

  it("keeps a matching leaf's ancestors even though they do not themselves match", () => {
    const tree = buildCoaTree(accounts, new Set(["leafA"]));
    expect(tree.map((r) => r.account.code)).toEqual(["1000", "1100", "1101"]);
  });

  it("drops a branch with no included account at all", () => {
    const tree = buildCoaTree(accounts, new Set(["other"]));
    expect(tree.map((r) => r.account.code)).toEqual(["2000"]);
  });
});

describe("matchesCoaStatus / parseCoaStatusFilter", () => {
  it("null matches both statuses", () => {
    expect(matchesCoaStatus(account({ status: "inactive" }), null)).toBe(true);
  });

  it("a specific status matches only that status", () => {
    expect(matchesCoaStatus(account({ status: "active" }), "inactive")).toBe(false);
  });

  it("parseCoaStatusFilter accepts active/inactive only", () => {
    expect(parseCoaStatusFilter("active")).toBe("active");
    expect(parseCoaStatusFilter("bogus")).toBeUndefined();
  });
});

describe("matchesCoaQuery", () => {
  it("matches the account code or name", () => {
    expect(matchesCoaQuery(account({ code: "1101" }), "1101")).toBe(true);
    expect(matchesCoaQuery(account({ name: "Kas Kecil" }), "kecil")).toBe(true);
    expect(matchesCoaQuery(account(), "tidak-ada")).toBe(false);
  });
});

describe("coaVisibleIds", () => {
  it("returns undefined when no filter is active, so buildCoaTree shows everything", () => {
    expect(coaVisibleIds([account()], null, "")).toBeUndefined();
  });

  it("returns the matching ids when a status or query filter is active", () => {
    const rows = [account({ id: "a", status: "active" }), account({ id: "b", status: "inactive" })];
    expect(coaVisibleIds(rows, "inactive", "")).toEqual(new Set(["b"]));
  });
});

describe("accountClassLabel", () => {
  it("humanizes a known account_class", () => {
    expect(accountClassLabel("asset")).toBe("Aset");
    expect(accountClassLabel("expense")).toBe("Beban");
  });

  it("falls back to the raw value for an unknown account_class", () => {
    expect(accountClassLabel("mystery")).toBe("mystery");
  });
});

describe("coaIndicators", () => {
  it("flags a group account", () => {
    expect(coaIndicators(account({ is_group: true }))).toEqual([{ text: "Grup", tone: "neutral" }]);
  });

  it("flags a control account", () => {
    expect(coaIndicators(account({ is_control: true }))).toContainEqual({
      text: "Akun Kontrol",
      tone: "attention",
    });
  });

  it("flags a protected leaf account that does not allow manual posting", () => {
    expect(coaIndicators(account({ allows_manual_posting: false }))).toContainEqual({
      text: "Dilindungi",
      tone: "attention",
    });
  });

  it("a group account never also shows Dilindungi even when allows_manual_posting is false", () => {
    const indicators = coaIndicators(account({ is_group: true, allows_manual_posting: false }));
    expect(indicators).toEqual([{ text: "Grup", tone: "neutral" }]);
  });

  it("an ordinary postable leaf has no indicators", () => {
    expect(coaIndicators(account())).toEqual([]);
  });
});
