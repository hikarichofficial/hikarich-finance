import { requirePermission } from "@/services/identity/access";
import { activeMemberships, can } from "@/domain/authz/access";
import {
  getBalanceSheet,
  getCashFlowStatement,
  getConsolidatedCashPosition,
  getEntityBaseCurrency,
  getGeneralLedger,
  getProfitAndLoss,
  getStatementOfChangesInEquity,
  listReportDatasets,
  runCustomReport,
} from "@/services/reports/reports";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import {
  resolveAsOfDate,
  resolveCompareRange,
  resolveConsolidatedEntityIds,
  resolveCustomReportDataset,
  resolveGeneralLedgerAccount,
  resolveReportRange,
} from "@/domain/reports/reports";
import type { ReportDatasetKey } from "@/schemas/reports";
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
  "custom",
  "consolidated",
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
 * carries `reports.view` in the seed catalog) to populate its account picker. The P&L tab additionally
 * accepts an optional `?compare_from=&compare_to=` pair (decision 189's own deferred item): when both are
 * present and valid, `profit_and_loss`'s own `p_compare_start`/`p_compare_end` are passed through unchanged
 * and the RPC does the comparison-period aggregation itself -- this route never computes one figure of a
 * comparison independently. The Custom Report Builder tab (decision 192, fourth increment) reads
 * `listReportDatasets` (a plain permission-gated table, not an RPC) and keeps only the datasets the active
 * membership actually holds `required_permission` for (checked locally via `can`, never a second round trip),
 * so the picker only ever offers a dataset `run_custom_report` will accept -- it never surfaces a choice the
 * RPC would then reject with FORBIDDEN. The Consolidated Analysis tab (decision 193, fifth increment) is the
 * one statement not scoped to the active Entity: it reads every membership `requirePermission` already
 * loaded (`access.memberships`) and keeps only the ones the caller holds `reports.cross_entity` for, so the
 * Entity checkboxes only ever offer a selection `consolidated_cash_position` will accept -- the same
 * filter-before-offering shape the Custom Report Builder tab uses for datasets. Each selected Entity's own
 * base currency is looked up separately (the RPC returns none), never assumed to match the active Entity's. */
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
    compare_from?: string;
    compare_to?: string;
    dataset?: string;
    entities?: string | string[];
  }>;
}) {
  const {
    entity,
    statement: statementParam,
    from,
    to,
    as_of,
    account,
    compare_from,
    compare_to,
    dataset,
    entities,
  } = await searchParams;
  const { access, membership } = await requirePermission("reports.view", { entityCode: entity });
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
  } else if (statement === "custom") {
    const catalog = await listReportDatasets();
    const datasets = catalog.filter((d) =>
      can(access, membership.entity_id, d.required_permission),
    );
    const datasetKey = resolveCustomReportDataset(datasets, dataset);
    const rows = datasetKey
      ? await runCustomReport({
          entity_id: membership.entity_id,
          dataset: datasetKey as ReportDatasetKey,
          start_date: range.from,
          end_date: range.to,
        })
      : [];
    data = { statement, range, datasets, datasetKey, rows };
  } else if (statement === "consolidated") {
    const eligible = activeMemberships(access).filter((m) =>
      can(access, m.entity_id, "reports.cross_entity"),
    );
    const requestedIds = Array.isArray(entities) ? entities : entities ? [entities] : [];
    const entityIds = resolveConsolidatedEntityIds(eligible, requestedIds);
    const rows =
      entityIds.length > 0
        ? await getConsolidatedCashPosition({ entity_ids: entityIds, as_of: asOf })
        : [];
    const currencyEntries = await Promise.all(
      rows.map(async (r) => [r.entity_id, await getEntityBaseCurrency(r.entity_id)] as const),
    );
    const currencyByEntity = Object.fromEntries(currencyEntries);
    data = { statement, asOf, eligible, entityIds, rows, currencyByEntity };
  } else {
    const compareRange = resolveCompareRange(compare_from, compare_to);
    const rows = await getProfitAndLoss({
      entity_id: membership.entity_id,
      start_date: range.from,
      end_date: range.to,
      compare_start_date: compareRange?.from,
      compare_end_date: compareRange?.to,
    });
    data = { statement, range, compareRange, rows };
  }

  return <ReportsScreen data={data} entity={entity} currency={currency} />;
}
