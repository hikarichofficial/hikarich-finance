import { describe, expect, it } from "vitest";
import {
  RULE_FAMILY_FILTER_OPTIONS,
  RULE_STATUS_FILTER_OPTIONS,
  filterTaxRuleRows,
  matchesRuleFamily,
  matchesRuleStatus,
  matchesTaxRuleQuery,
  parseRuleFamilyFilter,
  parseRuleStatusFilter,
  ruleFamilyLabel,
} from "./taxRulesList";
import type { TaxRuleVersionRow } from "@/schemas/tax";

function row(overrides: Partial<TaxRuleVersionRow> = {}): TaxRuleVersionRow {
  return {
    id: "11111111-1111-1111-1111-111111111111",
    family: "ppn",
    code: "PPN_STANDARD",
    rule_version: 1,
    effective_from: "2026-04-01",
    is_repeal: false,
    params: { rate: "0.11" },
    source_title: "PP 49 Tahun 2022",
    source_ref: "PP 49/2022 Pasal 2",
    source_url: "https://peraturan.bpk.go.id/Details/227560",
    verified_on: "2026-09-01",
    verification_status: "verified",
    status: "published",
    notes: null,
    published_at: "2026-09-02T00:00:00Z",
    discarded_at: null,
    discard_reason: null,
    created_at: "2026-09-01T00:00:00Z",
    updated_at: "2026-09-02T00:00:00Z",
    ...overrides,
  };
}

describe("ruleFamilyLabel", () => {
  it("labels a known family in Indonesian", () => {
    expect(ruleFamilyLabel("ppn")).toBe("PPN");
    expect(ruleFamilyLabel("fiscal_depreciation")).toBe("Penyusutan Fiskal");
  });

  it("shows an unrecognised family as itself, rather than throwing", () => {
    expect(ruleFamilyLabel("something_new")).toBe("something_new");
  });
});

describe("matchesRuleFamily / matchesRuleStatus", () => {
  const r = row();

  it("matches null as no filter", () => {
    expect(matchesRuleFamily(r, null)).toBe(true);
    expect(matchesRuleStatus(r, null)).toBe(true);
  });

  it("matches an exact value and rejects a different one", () => {
    expect(matchesRuleFamily(r, "ppn")).toBe(true);
    expect(matchesRuleFamily(r, "pph23")).toBe(false);
    expect(matchesRuleStatus(r, "published")).toBe(true);
    expect(matchesRuleStatus(r, "draft")).toBe(false);
  });
});

describe("matchesTaxRuleQuery", () => {
  it("matches the code case-insensitively", () => {
    expect(matchesTaxRuleQuery(row(), "ppn_standard")).toBe(true);
    expect(matchesTaxRuleQuery(row(), "tidak ada")).toBe(false);
  });

  it("matches the source title or reference too", () => {
    expect(matchesTaxRuleQuery(row(), "PP 49 Tahun 2022")).toBe(true);
    expect(matchesTaxRuleQuery(row(), "pasal 2")).toBe(true);
  });

  it("treats an empty query as matching everything", () => {
    expect(matchesTaxRuleQuery(row(), "")).toBe(true);
  });
});

describe("filterTaxRuleRows", () => {
  it("applies every predicate together", () => {
    const rows = [
      row({ id: "1", family: "ppn", status: "published", code: "PPN_STANDARD" }),
      row({ id: "2", family: "pph23", status: "published", code: "PPH23_STANDARD" }),
      row({ id: "3", family: "ppn", status: "draft", code: "PPN_STANDARD" }),
    ];
    const result = filterTaxRuleRows(rows, "ppn", "published", "");
    expect(result.map((r) => r.id)).toEqual(["1"]);
  });
});

describe("parseRuleFamilyFilter / parseRuleStatusFilter", () => {
  it("accepts a listed value and rejects anything else", () => {
    expect(parseRuleFamilyFilter("ppn")).toBe("ppn");
    expect(parseRuleFamilyFilter("not_a_family")).toBeUndefined();
    expect(parseRuleStatusFilter("draft")).toBe("draft");
    expect(parseRuleStatusFilter("nope")).toBeUndefined();
  });
});

describe("RULE_FAMILY_FILTER_OPTIONS / RULE_STATUS_FILTER_OPTIONS", () => {
  it("leads with an unfiltered 'all' option", () => {
    expect(RULE_FAMILY_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Kelompok" });
    expect(RULE_STATUS_FILTER_OPTIONS[0]).toEqual({ value: null, label: "Semua Status" });
  });

  it("lists every known family and status once", () => {
    expect(RULE_FAMILY_FILTER_OPTIONS).toHaveLength(13); // "all" + 12 families
    expect(RULE_STATUS_FILTER_OPTIONS).toHaveLength(4); // "all" + 3 statuses
  });
});
