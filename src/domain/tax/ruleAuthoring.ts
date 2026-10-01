import type { TaxRuleVersionRow } from "@/schemas/tax";

/**
 * Tax rule authoring (decision 249, OWNER answer to decision 239). The rule engine keeps using the rules
 * already in the master; the OWNER adjusts one by creating a new version prefilled from it (or edits a
 * draft), then publishes it with a step-up. The database validates every family's parameters
 * (`app_private.tax_rule_params_problem`), the verified source, and that a published version is never
 * changed. These helpers only prepare the form and decide which actions to show.
 */

export interface RuleFormDefaults {
  ruleId: string | null;
  family: string;
  code: string;
  lockedIdentity: boolean;
  effectiveFrom: string;
  isRepeal: boolean;
  paramsText: string;
  sourceTitle: string;
  sourceRef: string;
  sourceUrl: string;
  verifiedOn: string;
  verificationStatus: "verified" | "needs_review";
  notes: string;
}

/** Form defaults: editing a draft keeps its values; a new version copies a rule's values (so it follows
 * the existing rule until something is changed) with today's verification date; a brand-new rule starts
 * empty. */
export function ruleFormDefaults(
  base: TaxRuleVersionRow | null,
  mode: "edit_draft" | "new_version" | "new_rule",
  today: string,
): RuleFormDefaults {
  if (!base || mode === "new_rule") {
    return {
      ruleId: null,
      family: "other",
      code: "",
      lockedIdentity: false,
      effectiveFrom: today,
      isRepeal: false,
      paramsText: "{}",
      sourceTitle: "",
      sourceRef: "",
      sourceUrl: "",
      verifiedOn: today,
      verificationStatus: "needs_review",
      notes: "",
    };
  }
  const editing = mode === "edit_draft";
  return {
    ruleId: editing ? base.id : null,
    family: base.family,
    code: base.code,
    lockedIdentity: true,
    effectiveFrom: editing ? base.effective_from : today,
    isRepeal: editing ? base.is_repeal : false,
    paramsText: JSON.stringify(base.params, null, 2),
    sourceTitle: base.source_title,
    sourceRef: base.source_ref,
    sourceUrl: base.source_url ?? "",
    verifiedOn: editing ? base.verified_on : today,
    verificationStatus: editing ? base.verification_status : "needs_review",
    notes: editing ? (base.notes ?? "") : "",
  };
}

/** Parses the parameters text: it must be a JSON object. */
export function parseRuleParams(
  text: string,
): { ok: true; params: Record<string, unknown> } | { ok: false; message: string } {
  let value: unknown;
  try {
    value = JSON.parse(text.trim() === "" ? "{}" : text);
  } catch {
    return { ok: false, message: "Parameter bukan JSON yang valid." };
  }
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, message: "Parameter harus berupa objek JSON ({ ... })." };
  }
  return { ok: true, params: value as Record<string, unknown> };
}

/** Which authoring actions a rule version offers to someone with `tax.manage_rules`. A published rule is
 * never edited -- it is adjusted by a new version; only a draft can be edited, published or discarded. */
export function ruleAuthoringActions(
  rule: Pick<TaxRuleVersionRow, "status">,
  canManage: boolean,
): { newVersion: boolean; editDraft: boolean; publish: boolean; discard: boolean } {
  if (!canManage) return { newVersion: false, editDraft: false, publish: false, discard: false };
  return {
    newVersion: rule.status === "published",
    editDraft: rule.status === "draft",
    publish: rule.status === "draft",
    discard: rule.status === "draft",
  };
}

/** The database's own explanation after its `INVALID:`/`CONFLICT:` prefix, for showing next to the form. */
export function ruleProblemDetail(message: string | null | undefined): string | null {
  if (!message) return null;
  const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(message.trim());
  return match ? match[1] : null;
}
