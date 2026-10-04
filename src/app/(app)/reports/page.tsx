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
import { loanSummary, loansDue } from "@/services/financing/financing";
import { getPayrollControl, getPayrollSummary } from "@/services/payroll/payroll";
import { assetControl, assetMovement, fiscalSchedule, listAssets } from "@/services/assets/assets";
import {
  resolveAsOfDate,
  resolveCompareRange,
  resolveConsolidatedEntityIds,
  resolveCustomReportDataset,
  resolveFiscalScheduleAsset,
  resolveGeneralLedgerAccount,
  resolveLoanDueThrough,
  resolveReportRange,
} from "@/domain/reports/reports";
import type { ReportDatasetKey } from "@/schemas/reports";
import { reportQueryToSave } from "@/domain/reports/salesPurchase";
import { SaveReportForm } from "@/features/reports/SavedReportForms";
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
  "loans_due",
  "loan_summary",
  "payroll_summary",
  "payroll_control",
  "fiscal_schedule",
  "asset_control",
  "asset_movement",
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
 * base currency is looked up separately (the RPC returns none), never assumed to match the active Entity's.
 * The Loans Due and Loan Summary tabs (decision 195, seventh increment) read the already-built `loansDue`/
 * `loanSummary` wrappers (`@/services/financing/financing`, unused in a screen until now) -- unlike every
 * other tab here, their own RPCs (`loan_due`/`loan_summary`) are gated by `loans.view`, not `reports.view`,
 * and not every role holding `reports.view` also holds `loans.view` (the `tax` role is the one exception in
 * the seed catalog, confirmed against `20260920100100_p2_permission_catalog.sql`) -- so this route checks
 * `can(access, membership.entity_id, "loans.view")` before calling either RPC, the same "never surface a
 * choice the RPC would reject with FORBIDDEN" rule the Custom Report Builder and Consolidated Analysis tabs
 * already follow, and the screen renders a plain permission message instead of an error when it is false. The
 * Payroll Summary and Payroll Control tabs (decision 196, eighth increment) read the already-built
 * `getPayrollSummary`/`getPayrollControl` wrappers (`@/services/payroll/payroll`). Their own RPCs share the
 * compound "base payroll" gate already established for Payroll Runs/Payslips/Tax (decision 180:
 * `payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/`payroll.pay`) -- computed
 * here once as `canViewPayroll` and checked before either RPC is called, same pattern as `loans.view` above.
 * Payroll Control's own RPC additionally hard-requires `accounting.view` (it raises `FORBIDDEN` without it,
 * unlike the row/column masking `payroll.tax_view` does inside `payroll_summary_report`), so its own `canView`
 * is `canViewPayroll && can(access, membership.entity_id, "accounting.view")`. The Fiscal Depreciation Schedule
 * and Asset GL Reconciliation tabs (decision 197, ninth increment) read the already-built `fiscalSchedule`/
 * `assetControl` wrappers (`@/services/assets/assets.ts`). `asset_fiscal_schedule` takes one asset, not the
 * active Entity, so this route also lists every asset (`listAssets`, gated the same as every other read here)
 * to populate its picker and resolves the requested one with `resolveFiscalScheduleAsset` -- the same
 * "always resolve to something sensible" contract `resolveGeneralLedgerAccount` already uses for the General
 * Ledger tab's own account picker. Both tabs are gated by `assets.view` plus a second hard-required permission
 * (`tax.view` for the schedule, `accounting.view` for the reconciliation) -- unlike Payroll Summary/Control,
 * the `accountant` and `viewer_auditor` seed roles already hold every permission either tab needs together
 * with `reports.view`, so both are reachable by an ordinary role, not only the OWNER. The Asset Movement/
 * Disposal report (decision 279, tenth increment) closes out the one Step 12 report-catalogue item decision
 * 178 left open (noted in decision 303's open-items list) -- it reads the new `asset_movement_report` RPC
 * via the `assetMovement` wrapper, gated by `assets.view` alone (the RPC's own single permission check, no
 * second hard-required permission unlike the two tabs above), and takes a date range like every other
 * Entity-scoped statement rather than one asset or one as-of date. */
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
    through?: string;
    asset?: string;
  }>;
}) {
  const rawParams = await searchParams;
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
    through: throughParam,
    asset: assetParam,
  } = rawParams;
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
  } else if (statement === "loans_due") {
    const through = resolveLoanDueThrough(throughParam);
    const canView = can(access, membership.entity_id, "loans.view");
    const rows = canView ? await loansDue({ entity_id: membership.entity_id, through }) : [];
    data = { statement, through, canView, rows };
  } else if (statement === "loan_summary") {
    const canView = can(access, membership.entity_id, "loans.view");
    const rows = canView
      ? await loanSummary({ entity_id: membership.entity_id, from: range.from, to: range.to })
      : [];
    data = { statement, range, canView, rows };
  } else if (statement === "payroll_summary") {
    const canView =
      can(access, membership.entity_id, "payroll.compensation_view") &&
      (can(access, membership.entity_id, "payroll.run") ||
        can(access, membership.entity_id, "payroll.approve") ||
        can(access, membership.entity_id, "payroll.pay"));
    const rows = canView
      ? await getPayrollSummary({ entity_id: membership.entity_id, from: range.from, to: range.to })
      : [];
    data = { statement, range, canView, rows };
  } else if (statement === "payroll_control") {
    const canViewPayroll =
      can(access, membership.entity_id, "payroll.compensation_view") &&
      (can(access, membership.entity_id, "payroll.run") ||
        can(access, membership.entity_id, "payroll.approve") ||
        can(access, membership.entity_id, "payroll.pay"));
    const canView = canViewPayroll && can(access, membership.entity_id, "accounting.view");
    const rows = canView
      ? await getPayrollControl({ entity_id: membership.entity_id, as_of: asOf })
      : [];
    data = { statement, asOf, canView, rows };
  } else if (statement === "fiscal_schedule") {
    const canView =
      can(access, membership.entity_id, "assets.view") &&
      can(access, membership.entity_id, "tax.view");
    const assets = canView ? await listAssets({ entity_id: membership.entity_id }) : [];
    const assetId = resolveFiscalScheduleAsset(assets, assetParam);
    const rows = assetId ? await fiscalSchedule(assetId) : [];
    data = { statement, assets, assetId, canView, rows };
  } else if (statement === "asset_control") {
    const canView =
      can(access, membership.entity_id, "assets.view") &&
      can(access, membership.entity_id, "accounting.view");
    const rows = canView ? await assetControl(membership.entity_id, asOf) : [];
    data = { statement, asOf, canView, rows };
  } else if (statement === "asset_movement") {
    const canView = can(access, membership.entity_id, "assets.view");
    const rows = canView ? await assetMovement(membership.entity_id, range.from, range.to) : [];
    data = { statement, range, canView, rows };
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

  return (
    <>
      <ReportsScreen data={data} entity={entity} currency={currency} />
      <SaveReportForm
        entity={entity}
        path="/reports"
        query={reportQueryToSave({ ...rawParams, statement })}
      />
    </>
  );
}
