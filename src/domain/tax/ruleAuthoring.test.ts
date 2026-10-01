import { describe, expect, it } from "vitest";
import type { TaxRuleVersionRow } from "@/schemas/tax";
import {
  parseRuleParams,
  ruleAuthoringActions,
  ruleFormDefaults,
  ruleProblemDetail,
} from "./ruleAuthoring";

const published: TaxRuleVersionRow = {
  id: "00000000-0000-4000-8000-000000000001",
  family: "pph23",
  code: "PPH23_RATE",
  rule_version: 1,
  effective_from: "2009-01-01",
  is_repeal: false,
  params: { rate: "0.02" },
  source_title: "UU PPh",
  source_ref: "Pasal 23",
  source_url: null,
  verified_on: "2026-09-01",
  verification_status: "verified",
  status: "published",
  notes: "catatan lama",
  published_at: "2026-09-01T00:00:00Z",
  discarded_at: null,
  discard_reason: null,
  created_at: "2026-09-01T00:00:00Z",
  updated_at: "2026-09-01T00:00:00Z",
};

describe("ruleFormDefaults", () => {
  it("copies an existing rule into a new version that follows it", () => {
    const d = ruleFormDefaults(published, "new_version", "2026-10-01");
    expect(d.ruleId).toBeNull();
    expect(d.code).toBe("PPH23_RATE");
    expect(d.lockedIdentity).toBe(true);
    expect(JSON.parse(d.paramsText)).toEqual({ rate: "0.02" });
    expect(d.effectiveFrom).toBe("2026-10-01");
    expect(d.verifiedOn).toBe("2026-10-01");
    expect(d.verificationStatus).toBe("needs_review");
    expect(d.notes).toBe("");
  });

  it("keeps a draft's own values when editing it", () => {
    const draft = { ...published, status: "draft" as const, effective_from: "2027-01-01" };
    const d = ruleFormDefaults(draft, "edit_draft", "2026-10-01");
    expect(d.ruleId).toBe(draft.id);
    expect(d.effectiveFrom).toBe("2027-01-01");
    expect(d.verificationStatus).toBe("verified");
  });

  it("starts empty for a brand-new rule", () => {
    const d = ruleFormDefaults(null, "new_rule", "2026-10-01");
    expect(d.code).toBe("");
    expect(d.lockedIdentity).toBe(false);
    expect(d.paramsText).toBe("{}");
  });
});

describe("parseRuleParams", () => {
  it("accepts a JSON object", () => {
    expect(parseRuleParams('{"rate":"0.02"}')).toEqual({ ok: true, params: { rate: "0.02" } });
    expect(parseRuleParams("  ")).toEqual({ ok: true, params: {} });
  });

  it("refuses invalid JSON, arrays and scalars", () => {
    expect(parseRuleParams("{rate:").ok).toBe(false);
    expect(parseRuleParams("[1]").ok).toBe(false);
    expect(parseRuleParams("2").ok).toBe(false);
    expect(parseRuleParams("null").ok).toBe(false);
  });
});

describe("ruleAuthoringActions", () => {
  it("offers a new version on a published rule only", () => {
    expect(ruleAuthoringActions({ status: "published" }, true)).toEqual({
      newVersion: true,
      editDraft: false,
      publish: false,
      discard: false,
    });
  });

  it("offers edit, publish and discard on a draft", () => {
    expect(ruleAuthoringActions({ status: "draft" }, true)).toEqual({
      newVersion: false,
      editDraft: true,
      publish: true,
      discard: true,
    });
  });

  it("offers nothing on a discarded rule or without permission", () => {
    expect(Object.values(ruleAuthoringActions({ status: "discarded" }, true))).not.toContain(true);
    expect(Object.values(ruleAuthoringActions({ status: "draft" }, false))).not.toContain(true);
  });
});

describe("ruleProblemDetail", () => {
  it("keeps the database's explanation after the prefix", () => {
    expect(ruleProblemDetail("INVALID: rule parameters: rate must be a decimal")).toBe(
      "rule parameters: rate must be a decimal",
    );
    expect(ruleProblemDetail("CONFLICT: only a draft can be published (now published)")).toBe(
      "only a draft can be published (now published)",
    );
  });

  it("returns null for other messages", () => {
    expect(ruleProblemDetail("FORBIDDEN: missing tax.manage_rules")).toBeNull();
    expect(ruleProblemDetail(null)).toBeNull();
  });
});
