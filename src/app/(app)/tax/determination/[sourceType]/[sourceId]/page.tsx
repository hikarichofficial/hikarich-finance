import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listTaxDeterminations } from "@/services/tax/tax";
import { TaxDeterminationDetailScreen } from "@/features/tax/TaxDeterminationDetailScreen";

const SOURCE_TYPES = new Set(["invoice", "bill", "expense"]);

/** Tax Determination Detail (P13 Part 3e, Step 09 §15), reached only from a Tax Ledger row whose source is a
 * document (`taxDeterminationHref` never links a `period` source -- that belongs to the PPh Final UMKM family
 * of screens, deferred to a later increment). An empty result is not a 404: a document can genuinely have no
 * determination yet (still a draft, tax engine not active when it was posted, Step 05 §1), and the screen
 * shows that state itself rather than treating it as a missing page. */
export default async function TaxDeterminationDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ sourceType: string; sourceId: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { sourceType, sourceId } = await params;
  const { entity } = await searchParams;
  if (!SOURCE_TYPES.has(sourceType)) notFound();
  const { membership } = await requirePermission("tax.view", { entityCode: entity });

  const determinations = await listTaxDeterminations(
    sourceType as "invoice" | "bill" | "expense",
    sourceId,
  ).catch(() => null);
  if (determinations === null) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const backHref = entity ? `/tax/ledger?entity=${encodeURIComponent(entity)}` : "/tax/ledger";

  return (
    <TaxDeterminationDetailScreen
      sourceType={sourceType}
      sourceId={sourceId}
      determinations={determinations}
      currency={currency}
      entity={entity}
      backHref={backHref}
    />
  );
}
