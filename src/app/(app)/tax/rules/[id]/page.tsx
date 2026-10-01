import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { listTaxRuleVersions } from "@/services/tax/tax";
import { TaxRuleDetailScreen } from "@/features/tax/TaxRuleDetailScreen";

/** Tax Rule Detail (decision 239, Step 05 §13). No per-rule RPC exists, so the page looks the row up from
 * the full `listTaxRuleVersions` read, the same shape `PeriodClosePage`/`CustomerDetailPage` already use for
 * a Detail screen with no dedicated single-row RPC. A rule id that is not present (never existed, or the
 * caller's `tax.view` gate already failed above) lands here as "not found". */
export default async function TaxRuleDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  await requirePermission("tax.view", { entityCode: entity });

  const allRows = await listTaxRuleVersions();
  const rule = allRows.find((row) => row.id === id);
  if (!rule) notFound();

  const siblings = allRows.filter((row) => row.code === rule.code);
  const backHref = entity ? `/tax/rules?entity=${encodeURIComponent(entity)}` : "/tax/rules";

  return (
    <TaxRuleDetailScreen rule={rule} siblings={siblings} backHref={backHref} entity={entity} />
  );
}
