"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import type { EvidencePurpose, FilingTaxType } from "@/domain/tax/tax";
import {
  linkTaxEvidence,
  recordTaxFiling,
  recordTaxPayment,
  reconcileTaxPeriod,
  reverseTaxPayment,
} from "@/services/tax/tax";

/**
 * Server actions behind the Filing & Evidence screen (P13 unbuilt-screens backlog, "Filing & Evidence" nav
 * item, Step 05 §9, decision 238) -- the period-closing action set decision 235 deliberately deferred out of
 * `/tax/pph`, `/tax/withholding` and `/tax/ppn`: recording a payment (and reversing one), recording a filing
 * (original or amendment), reconciling the period, and attaching evidence to a filing or a payment. Every
 * write RPC here needs `tax.mark_filed` -- narrower than the page's own `tax.view` gate, same "let the RPC's
 * own narrower permission fail on submit" shape `taxFinalActions.ts`/`ReverseForm`/`PeriodActions` already
 * use. On success each action redirects back to the same tax type and period on `/tax/filing`, since every
 * RPC here posts (or links) immediately with no draft of its own to view elsewhere.
 */

export interface TaxFilingActionState {
  status: "idle" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function optionalText(formData: FormData, name: string): string | undefined {
  const value = text(formData, name);
  return value === "" ? undefined : value;
}

function errorState(error: unknown, fallback: string): TaxFilingActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: describeAuthzError(error) };
  }
  return { status: "error", message: fallback };
}

function backToFiling(entity: string, taxType: string, period: string): never {
  const qs = new URLSearchParams({ type: taxType, period: period.slice(0, 7) });
  if (entity) qs.set("entity", entity);
  redirect(`/tax/filing?${qs.toString()}`);
}

export async function recordTaxPaymentAction(
  _previous: TaxFilingActionState,
  formData: FormData,
): Promise<TaxFilingActionState> {
  const entity = text(formData, "entity");
  const taxType = text(formData, "tax_type");
  const period = text(formData, "period");
  try {
    await recordTaxPayment({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      tax_type: taxType as FilingTaxType,
      period,
      payment_date: text(formData, "payment_date"),
      account_id: optionalText(formData, "account_id") ?? null,
      payable: text(formData, "payable"),
      asset_offset: optionalText(formData, "asset_offset"),
      penalty: optionalText(formData, "penalty"),
      reference: optionalText(formData, "reference"),
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Pembayaran pajak tidak dapat dicatat.");
  }
  backToFiling(entity, taxType, period);
}

export async function reverseTaxPaymentAction(
  _previous: TaxFilingActionState,
  formData: FormData,
): Promise<TaxFilingActionState> {
  const entity = text(formData, "entity");
  const taxType = text(formData, "tax_type");
  const period = text(formData, "period");
  try {
    await reverseTaxPayment({
      payment_id: text(formData, "payment_id"),
      idempotency_key: randomUUID(),
      date: text(formData, "date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(error, "Pembayaran pajak tidak dapat dibatalkan.");
  }
  backToFiling(entity, taxType, period);
}

export async function recordTaxFilingAction(
  _previous: TaxFilingActionState,
  formData: FormData,
): Promise<TaxFilingActionState> {
  const entity = text(formData, "entity");
  const taxType = text(formData, "tax_type");
  const period = text(formData, "period");
  try {
    await recordTaxFiling({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      tax_type: taxType as FilingTaxType,
      period,
      filed_date: text(formData, "filed_date"),
      reference: text(formData, "reference"),
      reported_base: text(formData, "reported_base"),
      reported_tax: text(formData, "reported_tax"),
      reported_credit: optionalText(formData, "reported_credit"),
      amendment: text(formData, "amendment") === "true",
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Pelaporan pajak tidak dapat dicatat.");
  }
  backToFiling(entity, taxType, period);
}

export async function reconcileTaxPeriodAction(
  _previous: TaxFilingActionState,
  formData: FormData,
): Promise<TaxFilingActionState> {
  const entity = text(formData, "entity");
  const taxType = text(formData, "tax_type");
  const period = text(formData, "period");
  try {
    await reconcileTaxPeriod({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      tax_type: taxType as FilingTaxType,
      period,
      note: optionalText(formData, "note"),
    });
  } catch (error) {
    return errorState(error, "Periode ini tidak dapat direkonsiliasi.");
  }
  backToFiling(entity, taxType, period);
}

export async function linkTaxEvidenceAction(
  _previous: TaxFilingActionState,
  formData: FormData,
): Promise<TaxFilingActionState> {
  const entity = text(formData, "entity");
  const taxType = text(formData, "tax_type");
  const period = text(formData, "period");
  try {
    await linkTaxEvidence({
      document_id: text(formData, "document_id"),
      target_type: text(formData, "target_type") === "tax_payment" ? "tax_payment" : "tax_filing",
      target_id: text(formData, "target_id"),
      purpose: optionalText(formData, "purpose") as EvidencePurpose | undefined,
    });
  } catch (error) {
    return errorState(error, "Dokumen tidak dapat dilampirkan.");
  }
  backToFiling(entity, taxType, period);
}
