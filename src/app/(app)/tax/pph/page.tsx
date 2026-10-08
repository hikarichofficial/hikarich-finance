import { requirePermission } from "@/services/identity/access";
import {
  estimateFinalTax,
  getEntityBaseCurrency,
  getTaxPeriodPosition,
  previewFinalTax,
} from "@/services/tax/tax";
import { resolveTaxPeriod, runningTaxPeriod } from "@/domain/tax/tax";
import { TaxFinalScreen } from "@/features/tax/TaxFinalScreen";

/** PPh Final UMKM (P13 unbuilt-screens backlog, "PPh Final / Income Tax" nav item, Step 05 §9, decision 234).
 * `?period=` takes a native `<input type="month">`'s own "YYYY-MM" value; an absent or invalid one falls
 * back to the most recently completed month (`resolveTaxPeriod`). Gated `tax.view` -- `tax_final_preview`'s
 * and `tax_period_position`'s own exact check -- which happens to already be the Tax nav section's own
 * parent-item permission. The final tax of an ended month is computed by the scheduled job (decision 346), so
 * the screen has no compute button. */
export default async function TaxFinalPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; period?: string }>;
}) {
  const { entity, period: periodParam } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const period = resolveTaxPeriod(periodParam);

  const runningPeriod = runningTaxPeriod();
  const [preview, position, currency, estimate] = await Promise.all([
    previewFinalTax({ entity_id: membership.entity_id, period }),
    getTaxPeriodPosition({ entity_id: membership.entity_id, tax_type: "final_umkm", period }),
    getEntityBaseCurrency(membership.entity_id),
    estimateFinalTax({ entity_id: membership.entity_id, period: runningPeriod }),
  ]);

  return (
    <TaxFinalScreen
      period={period}
      preview={preview}
      position={position}
      currency={currency}
      entity={entity}
      estimate={estimate}
      estimatePeriod={runningPeriod}
    />
  );
}
