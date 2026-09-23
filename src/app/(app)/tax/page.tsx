import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getTaxOverview } from "@/services/tax/tax";
import { TaxOverviewScreen } from "@/features/tax/TaxOverviewScreen";

/** Tax Overview (P13 Part 3e, Step 09 §15): the Tax nav group's own landing screen. */
export default async function TaxOverviewPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });

  const [overview, currency] = await Promise.all([
    getTaxOverview(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return <TaxOverviewScreen overview={overview} currency={currency} entity={entity} />;
}
