import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import {
  getAccountActivity,
  getMoneyControl,
  getReconciliationStatus,
} from "@/services/money/money";
import { mergeAccountRows, resolveActivityRange } from "@/domain/money/accountsList";
import { AccountDetailScreen } from "@/features/money/AccountDetailScreen";

/** Account Detail (P13 Part 3c, Step 09 §10, §13). Permission is read off the currently active Entity
 * (`?entity=`), the same per-page pattern every other screen uses (DECISIONS 158). `money_control`/
 * `reconciliation_status` are Entity-scoped (no per-account RPC variant exists), so the page fetches both for
 * the active Entity and looks up the one row by id -- the same shape `getBillDetail` already uses for
 * `list_bill_positions`. An id belonging to a different Entity's account, or one the caller cannot see
 * (`money.view` failed already, above), lands here as "not found", never a cross-Entity leak. */
export default async function AccountDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string; from?: string; to?: string }>;
}) {
  const { id } = await params;
  const { entity, from, to } = await searchParams;
  const { membership } = await requirePermission("money.view", { entityCode: entity });

  const [control, reconciliation] = await Promise.all([
    getMoneyControl(membership.entity_id),
    getReconciliationStatus(membership.entity_id),
  ]);
  const account = mergeAccountRows(control, reconciliation).find(
    (row) => row.financial_account_id === id,
  );
  if (!account) notFound();

  const range = resolveActivityRange(from, to);
  const activity = await getAccountActivity(id, { from: range.from, to: range.to, limit: 500 });

  const backHref = entity
    ? `/money/accounts?entity=${encodeURIComponent(entity)}`
    : "/money/accounts";

  return (
    <AccountDetailScreen
      account={account}
      activity={activity}
      backHref={backHref}
      range={range}
      entity={entity}
    />
  );
}
