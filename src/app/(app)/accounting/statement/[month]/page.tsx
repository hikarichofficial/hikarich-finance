import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getCashStatement, listCashAccountOptions } from "@/services/accounting/cashStatement";
import { getEntityBaseCurrency } from "@/services/reports/reports";
import {
  parseStatementMonth,
  parseStatementPage,
  STATEMENT_PAGE_SIZE,
} from "@/domain/accounting/cashStatement";
import { CashStatementScreen } from "@/features/accounting/CashStatementScreen";

/** Rekening Koran of one month (decision 327): its own page, so the lines can be read in focus and in pages. */
export default async function CashStatementMonthPage({
  params,
  searchParams,
}: {
  params: Promise<{ month: string }>;
  searchParams: Promise<{ entity?: string; account?: string; page?: string }>;
}) {
  const { month } = await params;
  const { entity, account, page: pageParam } = await searchParams;
  const monthStart = parseStatementMonth(month);
  if (!monthStart) notFound();
  const { membership } = await requirePermission("accounting.view", { entityCode: entity });
  const page = parseStatementPage(pageParam);
  const accountId = account && /^[0-9a-f-]{36}$/i.test(account) ? account : null;

  const [statement, accounts, currency] = await Promise.all([
    getCashStatement({
      entityId: membership.entity_id,
      financialAccountId: accountId,
      month: monthStart,
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
