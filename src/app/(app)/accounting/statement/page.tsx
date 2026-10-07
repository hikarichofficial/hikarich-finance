import { requirePermission } from "@/services/identity/access";
import { getCashStatement, listCashAccountOptions } from "@/services/accounting/cashStatement";
import { getEntityBaseCurrency } from "@/services/reports/reports";
import { parseStatementYear } from "@/domain/accounting/cashStatement";
import { CashStatementYearScreen } from "@/features/accounting/CashStatementYearScreen";

/**
 * Rekening Koran (decisions 326-327): the twelve months of a chosen year. The database returns the twelve
 * months ending at the month asked for, so asking for December gives January to December of that year.
 */
export default async function CashStatementPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; account?: string; year?: string }>;
}) {
  const { entity, account, year: yearParam } = await searchParams;
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });
  const currentYear = new Date().getFullYear();
  const year = parseStatementYear(yearParam, currentYear);
  const accountId = account && /^[0-9a-f-]{36}$/i.test(account) ? account : null;

  const [statement, accounts, currency] = await Promise.all([
    getCashStatement({
      entityId: membership.entity_id,
      financialAccountId: accountId,
      month: `${year}-12-01`,
      limit: 1,
      offset: 0,
    }),
    listCashAccountOptions(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <CashStatementYearScreen
      statement={statement}
      accounts={accounts}
      accountId={accountId}
      year={year}
      currentYear={currentYear}
      currency={currency}
      entity={entity}
    />
  );
}
