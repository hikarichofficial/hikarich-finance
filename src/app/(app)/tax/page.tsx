import { requirePermission } from "@/services/identity/access";
import {
  estimateFinalTax,
  getEntityBaseCurrency,
  getNonFinalIncome,
  getPersonalTaxSummary,
  getTaxGroupTurnover,
  getTaxOverview,
  listTaxLedger,
} from "@/services/tax/tax";
import { resolveTaxYear, runningTaxPeriod } from "@/domain/tax/tax";
import { computePersonalTax } from "@/domain/tax/personalTax";
import { TaxOverviewScreen } from "@/features/tax/TaxOverviewScreen";

/** Tax Overview (P13 Part 3e, Step 09 §15): the Tax nav group's own landing screen. */
export default async function TaxOverviewPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; year?: string }>;
}) {
  const { entity, year } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });

  const period = runningTaxPeriod();
  const currentYear = Number(period.slice(0, 4));
  const shownYear = resolveTaxYear(year, currentYear);
  const isPersonal = membership.entity_type === "personal";
  const [overview, currency, estimate, nonFinal, ledger, group, personal] = await Promise.all([
    getTaxOverview(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
    estimateFinalTax({ entity_id: membership.entity_id, period }),
    getNonFinalIncome(membership.entity_id, shownYear),
    listTaxLedger({
      entity_id: membership.entity_id,
      from: `${shownYear}-01-01`,
      to: `${shownYear}-12-31`,
      limit: 1000,
    }),
    getTaxGroupTurnover(membership.entity_id, shownYear),
    isPersonal ? getPersonalTaxSummary(membership.entity_id, shownYear) : Promise.resolve(null),
  ]);
  const personalTax = personal ? computePersonalTax(personal) : null;

  return (
    <TaxOverviewScreen
      overview={overview}
      currency={currency}
      entity={entity}
      estimate={estimate}
      estimatePeriod={period}
      nonFinal={nonFinal}
      currentYear={currentYear}
      shownYear={shownYear}
      ledger={ledger}
      group={group}
      ownName={membership.entity_name}
      personalTax={personalTax}
    />
  );
}
