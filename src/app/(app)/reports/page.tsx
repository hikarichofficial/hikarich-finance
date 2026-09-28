import { requirePermission } from "@/services/identity/access";
import {
  getBalanceSheet,
  getCashFlowStatement,
  getEntityBaseCurrency,
  getGeneralLedger,
  getProfitAndLoss,
  getStatementOfChangesInEquity,
} from "@/services/reports/reports";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import {
  resolveAsOfDate,
  resolveGeneralLedgerAccount,
  resolveReportRange,
} from "@/domain/reports/reports";
import {
  ReportsScreen,
  type ReportStatement,
  type ReportsData,
} from "@/features/reports/ReportsScreen";

const REPORT_STATEMENTS: readonly ReportStatement[] = [
  "pnl",
  "balance_sheet",
  "equity",
  "cashflow",
  "gl",
];

function resolveStatement(value: string | undefined): ReportStatement {
  return (REPORT_STATEMENTS as readonly string[]).includes(value ?? "")
    ? (value as ReportStatement)
    : "pnl";
}

/** Financial Reports (P13 Part 4, Step 12 §3-§5). Reads only the already-built P12 statement RPCs
 * (`src/services/reports/reports.ts`) -- this route computes no financial figure of its own, matching the
 * P13 gate's own rule (decision 155: "never computing an independent frontend financial truth"). Only the
 * active statement's own RPC is called per request, chosen by `?statement=`; the General Ledger tab
 * (decision 190) additionally reads `listLedgerAccounts` (`accounting.view`-gated, same as every role that
 * carries `reports.view` in the seed catalog) to populate its account picker. */
export default async function ReportsPage({
  searchParams,
}: {
  searchParams: Promise<{
    entity?: string;
    statement?: string;
    from?: string;
    to?: string;
    as_of?: string;
    account?: string;
  }>;
}) {
  const { entity, statement: statementParam, from, to, as_of, account } = await searchParams;
  const { membership } = await requirePermission("reports.view", { entityCode: entity });
  const statement = resolveStatement(statementParam);
  const range = resolveReportRange(from, to);
  const asOf = resolveAsOfDate(as_of);
  const currency = await getEntityBaseCurrency(membership.entity_id);

  let data: ReportsData;
  if (statement === "balance_sheet") {
    const rows = await getBalanceSheet({ entity_id: membership.entity_id, as_of: asOf });
    data = { statement, asOf, rows };
  } else if (statement === "equity") {
    const rows = await getStatementOfChangesInEquity({
      entity_id: membership.entity_id,
      start_date: range.from,
      end_date: range.to,
    });
    data = { statement, range, rows };
  } else if (statement === "cashflow") {
    const rows = await getCashFlowStatement({
      entity_id: membership.entity_id,
      start_date: range.from,
      end_date: range.to,
    });
    data = { statement, range, rows };
  } else if (statement === "gl") {
    const allAccounts = await listLedgerAccounts(membership.entity_id);
    const accounts = allAccounts.filter((a) => !a.is_group);
    const accountId = resolveGeneralLedgerAccount(accounts, account);
    const rows = accountId
      ? await getGeneralLedger({
          entity_id: membership.entity_id,
          account_id: accountId,
          start_date: range.from,
          end_date: range.to,
        })
      : [];
    data = { statement, range, accountId, accounts, rows };
  } else {
    const rows = await getProfitAndLoss({
      entity_id: membership.entity_id,
      start_date: range.from,
      end_date: range.to,
    });
    data = { statement, range, rows };
  }

  return <ReportsScreen data={data} entity={entity} currency={currency} />;
}
