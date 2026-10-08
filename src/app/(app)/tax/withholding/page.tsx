import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getTaxPeriodPosition } from "@/services/tax/tax";
import {
  TAX_TYPE_LABELS,
  WITHHOLDING_TAX_TYPES,
  resolveTaxPeriod,
  resolveWithholdingTaxType,
} from "@/domain/tax/tax";
import { TaxPositionScreen } from "@/features/tax/TaxPositionScreen";

/** Withholding (P13 unbuilt-screens backlog, "Withholding" nav item, Step 09 §15, decision 235): the income
 * tax the Entity deducts from what it pays -- PPh 23, PPh 4(2) on rent of land/buildings and PPh 26 on
 * payments to non-residents (decision 256); `?type=` picks one, defaulting to PPh 23.
 * `?period=` takes a native `<input type="month">`'s own "YYYY-MM" value; an absent or invalid one falls
 * back to the most recently completed month (`resolveTaxPeriod`, shared with `/tax/pph`, decision 234).
 * Gated `tax.view` -- `tax_period_position`'s own exact check, already the Tax nav section's own parent
 * permission. Read-only: withholding is determined per document at bill/expense time (Step 05), not from
 * this screen -- paying, filing, reconciling and evidence stay deferred to Filing & Evidence. */
export default async function TaxWithholdingPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; period?: string; type?: string }>;
}) {
  const { entity, period: periodParam, type: typeParam } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const period = resolveTaxPeriod(periodParam);
  const taxType = resolveWithholdingTaxType(typeParam);

  const [position, currency] = await Promise.all([
    getTaxPeriodPosition({ entity_id: membership.entity_id, tax_type: taxType, period }),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <TaxPositionScreen
      taxType={taxType}
      title={`PPh Vendor: ${TAX_TYPE_LABELS[taxType]}`}
      typeOptions={WITHHOLDING_TAX_TYPES.map((t) => ({ value: t, label: TAX_TYPE_LABELS[t] }))}
      period={period}
      position={position}
      currency={currency}
      entity={entity}
    />
  );
}
