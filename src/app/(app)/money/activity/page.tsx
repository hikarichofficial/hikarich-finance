import { requirePermission } from "@/services/identity/access";
import { getJournalNumbers, getMoneyControl, listCashActivity } from "@/services/money/money";
import { resolveActivityRange } from "@/domain/money/accountsList";
import { filterCashActivityRows, mergeCashActivityRows } from "@/domain/money/cashActivity";
import { CashActivityScreen } from "@/features/money/CashActivityScreen";

/** Cash/Bank Activity (P13 Part 3c, Step 09 §9, §13). `?account=` and `?from=`/`?to=` filter a direct read of
 * `money_movements` (no RPC reads the Entity-wide feed; `account_activity` is single-account). Journal
 * numbers are resolved defensively (`getJournalNumbers`): a caller without `accounting.view` (a different
 * permission from this page's own `money.view` gate -- the same gap decision 168 already found for
 * `contacts.view`/`bills.view`) simply sees "—" in the Jurnal column instead of an error. */
export default async function CashActivityPage({
  searchParams,
}: {
  searchParams: Promise<{
    entity?: string;
    account?: string;
    from?: string;
    to?: string;
    q?: string;
  }>;
}) {
  const { entity, account, from, to, q } = await searchParams;
  const { membership } = await requirePermission("money.view", { entityCode: entity });
  const range = resolveActivityRange(from, to);
  const query = q ?? "";
  const accountId = account && account.trim() !== "" ? account : null;

  const [movements, accounts] = await Promise.all([
    listCashActivity(membership.entity_id, range),
    getMoneyControl(membership.entity_id),
  ]);
  const journalNumbers = await getJournalNumbers([...new Set(movements.map((m) => m.journal_id))]);
  const rows = mergeCashActivityRows(movements, accounts, journalNumbers);
  const visible = filterCashActivityRows(rows, accountId, query);

  return (
    <CashActivityScreen
      rows={visible}
      accounts={accounts}
      accountId={accountId}
      query={query}
      range={range}
      entity={entity}
    />
  );
}
