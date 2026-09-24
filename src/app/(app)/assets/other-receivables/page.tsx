import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listObligations } from "@/services/financing/financing";
import {
  filterObligationRows,
  parseObligationStatusFilter,
} from "@/domain/financing/obligationList";
import { ObligationRegisterScreen } from "@/features/financing/ObligationRegisterScreen";

/** Other Receivables (P13 Part 3f, third increment, Step 09 §9, §16). `kind` is fixed to `receivable` --
 * `obligation_list`/`obligation_detail` are gated on `loans.view`, not `assets.view` (confirmed directly against
 * `20260926100100_p8_other_obligations.sql`); the nav's own permission for this item was fixed to match
 * (decision 176 records this as a bug fix, the same "matching what the RPC already returns" treatment decision
 * 173 gave a similar schema gap). */
export default async function OtherReceivablesPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("loans.view", { entityCode: entity });
  const obligationStatus = parseObligationStatusFilter(status) ?? null;
  const query = q ?? "";

  const [entries, currency] = await Promise.all([
    listObligations({
      entity_id: membership.entity_id,
      kind: "receivable",
      status: obligationStatus ?? undefined,
    }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterObligationRows(entries, query);

  return (
    <ObligationRegisterScreen
      rows={rows}
      kind="receivable"
      status={obligationStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
