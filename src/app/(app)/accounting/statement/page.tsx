import { requirePermission } from "@/services/identity/access";
import { getCashStatement, listCashAccountOptions } from "@/services/accounting/cashStatement";
import { getEntityBaseCurrency } from "@/services/reports/reports";
import {
  parseStatementMonth,
  parseStatementPage,
  STATEMENT_PAGE_SIZE,
} from "@/domain/accounting/cashStatement";
import { CashStatementScreen } from "@/features/accounting/CashStatementScreen";

/** Rekening Koran (decision 326): monthly money in/out of the cash and bank accounts, in pages. */
export default async function CashStatementPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; account?: string; month?: string; page?: string }>;
}) {
  const { entity, account, month, page: pageParam } = await searchParams;
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });
  const page = parseStatementPage(pageParam);
  const accountId = account && /^[0-9a-f-]{36}$/i.test(account) ? account : null;

  const [statement, accounts, currency] = await Promise.all([
    getCashStatement({
      entityId: membership.entity_id,
      financialAccountId: accountId,
      month: parseStatementMonth(month),
      limit: STATEMENT_PAGE_SIZE,
      offset: (page - 1) * STATEMENT_PAGE_SIZE,
    }),
    listCashAccountOptions(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <CashStatementScreen
      statement={statement}
      accounts={accounts}
      accountId={accountId}
      page={page}
      currency={currency}
      entity={entity}
    />
  );
}
