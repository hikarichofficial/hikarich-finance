"use server";

import { randomUUID } from "node:crypto";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { computeFinalTax } from "@/services/tax/tax";

/**
 * Server action behind the PPh Final UMKM screen's "Hitung Pajak Final" button (P13 unbuilt-screens backlog,
 * "PPh Final / Income Tax" nav item, Step 05 §9, decision 234). `tax_final_compute` needs `tax.confirm_facts`
 * -- a narrower permission than the page's own `tax.view` gate (`tax_final_preview`/`tax_period_position`'s
 * own check) -- so a viewer without it reaches this screen and sees the figures, but this action's own
 * `AuthzError` surfaces the moment they try to compute, the same "let the RPC's own narrower permission fail
 * naturally" shape used throughout (`ReverseForm`, `PeriodActions`). It posts immediately with no draft of
 * its own, so on success this redirects back to the same period's own view -- `TaxOverviewScreen`'s "attention"
 * list and `getTaxPeriodPosition` will both show the freshly recorded determination once the page re-fetches.
 */

export interface ComputeFinalTaxFormState {
  status: "idle" | "error";
  message?: string;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

export async function computeFinalTaxAction(
  _previous: ComputeFinalTaxFormState,
  formData: FormData,
): Promise<ComputeFinalTaxFormState> {
  const entity = text(formData, "entity");
  const period = text(formData, "period");
  try {
    await computeFinalTax({
      entity_id: text(formData, "entity_id"),
      idempotency_key: randomUUID(),
      period,
    });
  } catch (error) {
    if (error instanceof AuthzError) {
      return { status: "error", message: describeAuthzError(error) };
    }
    return {
      status: "error",
      message: "Pajak final bulan ini tidak dapat dihitung sekarang.",
    };
  }
  const qs = new URLSearchParams({ period: period.slice(0, 7) });
  if (entity) qs.set("entity", entity);
  await setFlash("Pajak final dihitung.");
  redirect(`/tax/pph?${qs.toString()}`);
}
