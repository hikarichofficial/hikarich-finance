import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listEquityEvents } from "@/services/financing/financing";
import {
  filterEquityRows,
  parseEquityKindFilter,
  parseEquityStatusFilter,
} from "@/domain/financing/equityList";
import { EquityRegisterScreen } from "@/features/financing/EquityRegisterScreen";

/** Capital & Equity (P13 Part 3f, fourth increment, Step 09 §9, §16). `?kind=` and `?status=` are sent straight
 * to `equity_list`'s own `p_kind`/`p_status` arguments (server-side filtering, matching the Loan Register's own
 * pattern); `?q=` is a client-side number/counterparty/purpose search. */
export default async function EquityRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; kind?: string; status?: string; q?: string }>;
}) {
  const { entity, kind, status, q } = await searchParams;
  const { membership } = await requirePermission("equity.view", { entityCode: entity });
  const equityKind = parseEquityKindFilter(kind) ?? null;
  const equityStatus = parseEquityStatusFilter(status) ?? null;
  const query = q ?? "";

  const [entries, currency] = await Promise.all([
    listEquityEvents({
      entity_id: membership.entity_id,
      kind: equityKind ?? undefined,
      status: equityStatus ?? undefined,
    }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterEquityRows(entries, query);

  return (
    <EquityRegisterScreen
      rows={rows}
      kind={equityKind}
      status={equityStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
