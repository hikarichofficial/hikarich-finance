"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { parseRuleParams, ruleProblemDetail } from "@/domain/tax/ruleAuthoring";
import { discardRule, publishRule, saveRuleDraft } from "@/services/tax/tax";

/**
 * Tax rule authoring actions (decision 249). Each calls an existing P7 RPC that re-checks
 * `tax.manage_rules`, validates the family's parameters and the source, and (for publish) demands a recent
 * step-up and a verified source. The database's own explanation of an invalid draft is shown so the OWNER
 * can correct it.
 */

export interface RuleActionState {
  status: "idle" | "error";
  message?: string;
  detail?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function ruleHref(id: string, entity: string): string {
  return entity ? `/tax/rules/${id}?entity=${encodeURIComponent(entity)}` : `/tax/rules/${id}`;
}

function fail(error: unknown, fallback: string): RuleActionState {
  if (error instanceof AuthzError) {
    return {
      status: "error",
      message: authzErrorMessage(error.code),
      detail: ruleProblemDetail(error.message) ?? undefined,
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

export async function saveRuleDraftAction(
  _previous: RuleActionState,
  formData: FormData,
): Promise<RuleActionState> {
  const entity = text(formData, "entity");
  const parsed = parseRuleParams(String(formData.get("params") ?? ""));
  if (!parsed.ok) return { status: "error", message: parsed.message };
  let id: string;
  try {
    id = await saveRuleDraft({
      idempotency_key: randomUUID(),
      rule_id: text(formData, "rule_id") || null,
      family: text(formData, "family"),
      code: text(formData, "code"),
      effective_from: text(formData, "effective_from"),
      is_repeal: formData.get("is_repeal") === "on",
      params: parsed.params,
      source_title: text(formData, "source_title"),
      source_ref: text(formData, "source_ref") || undefined,
      source_url: text(formData, "source_url") || undefined,
      verified_on: text(formData, "verified_on") || null,
      verification_status:
        text(formData, "verification_status") === "verified" ? "verified" : "needs_review",
      notes: text(formData, "notes") || undefined,
    });
  } catch (error) {
    return fail(error, "Draf aturan tidak dapat disimpan. Periksa isian lalu coba lagi.");
  }
  revalidatePath("/tax/rules");
  redirect(ruleHref(id, entity));
}

export async function publishRuleAction(
  _previous: RuleActionState,
  formData: FormData,
): Promise<RuleActionState> {
  const entity = text(formData, "entity");
  let id: string;
  try {
    id = await publishRule({ rule_id: text(formData, "rule_id"), idempotency_key: randomUUID() });
  } catch (error) {
    return fail(error, "Aturan tidak dapat diterbitkan.");
  }
  revalidatePath("/tax/rules");
  redirect(ruleHref(id, entity));
}

export async function discardRuleAction(
  _previous: RuleActionState,
  formData: FormData,
): Promise<RuleActionState> {
  const entity = text(formData, "entity");
  const ruleId = text(formData, "rule_id");
  try {
    await discardRule({ rule_id: ruleId, reason: text(formData, "reason") });
  } catch (error) {
    return fail(error, "Draf tidak dapat dibatalkan. Alasan minimal 5 karakter.");
  }
  revalidatePath("/tax/rules");
  redirect(ruleHref(ruleId, entity));
}
