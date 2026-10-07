import { requirePermission } from "@/services/identity/access";
import { estimateFinalTax, getEntityBaseCurrency, getTaxCalendar } from "@/services/tax/tax";
import { runningTaxPeriod } from "@/domain/tax/tax";
import { resolveTaxCalendarRange } from "@/domain/tax/taxCalendarList";
import { TaxCalendarScreen } from "@/features/tax/TaxCalendarScreen";

/** Tax Calendar (P13 unbuilt-screens backlog, "Tax Calendar" nav item, Step 09 §15, decision 233). `?from=`/
 * `?to=` pick the window; an absent or invalid pair falls back to one month back through two months ahead of
 * today (`resolveTaxCalendarRange`). Gated on `tax.view` directly -- `tax_calendar`'s own exact permission
 * check -- which happens to be the same permission the "Tax" nav section's parent item already requires. */
export default async function TaxCalendarPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; from?: string; to?: string }>;
}) {
  const { entity, from, to } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const range = resolveTaxCalendarRange(from, to);

  const period = runningTaxPeriod();
  const [rows, currency, estimate] = await Promise.all([
    getTaxCalendar({ entity_id: membership.entity_id, from: range.from, to: range.to }),
    getEntityBaseCurrency(membership.entity_id),
    estimateFinalTax({ entity_id: membership.entity_id, period }),
  ]);

  return (
    <TaxCalendarScreen
      rows={rows}
      range={range}
      currency={currency}
      entity={entity}
      estimate={estimate}
      estimatePeriod={period}
    />
  );
}
