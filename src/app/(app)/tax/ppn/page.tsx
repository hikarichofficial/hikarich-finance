import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getTaxPeriodPosition } from "@/services/tax/tax";
import { resolveTaxPeriod } from "@/domain/tax/tax";
import { TaxPositionScreen } from "@/features/tax/TaxPositionScreen";

/** PPN (VAT) (P13 unbuilt-screens backlog, "PPN" nav item, Step 09 §15, decision 235). `?period=` takes a
 * native `<input type="month">`'s own "YYYY-MM" value; an absent or invalid one falls back to the most
 * recently completed month (`resolveTaxPeriod`, shared with `/tax/pph`, decision 234). Gated `tax.view` --
 * `tax_period_position`'s own exact check, already the Tax nav section's own parent permission. Read-only:
 * VAT is determined per document at invoice/bill time (Step 05), not from this screen -- paying, filing,
 * reconciling and evidence stay deferred to Filing & Evidence. */
export default async function TaxPpnPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; period?: string }>;
}) {
  const { entity, period: periodParam } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const period = resolveTaxPeriod(periodParam);

  const [position, currency] = await Promise.all([
    getTaxPeriodPosition({ entity_id: membership.entity_id, tax_type: "vat", period }),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <TaxPositionScreen
      taxType="vat"
      title="PPN"
      period={period}
      position={position}
      currency={currency}
      entity={entity}
    />
  );
}
