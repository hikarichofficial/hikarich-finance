import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listObligations } from "@/services/financing/financing";
import {
  filterObligationRows,
  parseObligationStatusFilter,
} from "@/domain/financing/obligationList";
import { ObligationRegisterScreen } from "@/features/financing/ObligationRegisterScreen";

/** Other Payables (P13 Part 3f, third increment, Step 09 §9, §16). See `other-receivables/page.tsx`'s own
 * comment for the `loans.view` permission-gate note; this page is otherwise identical with `kind` fixed to
 * `payable`. */
export default async function OtherPayablesPage({
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
      kind: "payable",
      status: obligationStatus ?? undefined,
    }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterObligationRows(entries, query);

  return (
    <ObligationRegisterScreen
      rows={rows}
      kind="payable"
      status={obligationStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
