import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getSalesPurchaseReport } from "@/services/reports/reports";
import { resolveReportRange } from "@/domain/reports/reports";
import { parseDimension, parseSide, reportQueryToSave } from "@/domain/reports/salesPurchase";
import { SalesPurchaseScreen } from "@/features/reports/SalesPurchaseScreen";
import { SaveReportForm } from "@/features/reports/SavedReportForms";

/** Sales/Purchase report (Step 09 §19, decision 252). `?side=sales|purchases`, `?by=party|category|
 * product|month`, `?from=&to=` (default: this year to date). Gated `reports.view`; the source permission
 * (`invoices.view` for sales, `bills.view` for purchases) is checked before calling, as the RPC does. */
export default async function SalesPurchaseReportPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; side?: string; by?: string; from?: string; to?: string }>;
}) {
  const params = await searchParams;
  const { access, membership } = await requirePermission("reports.view", {
    entityCode: params.entity,
  });
  const side = parseSide(params.side);
  const dimension = parseDimension(params.by, side);
  const range = resolveReportRange(params.from, params.to);
  const canView = can(
    access,
    membership.entity_id,
    side === "sales" ? "invoices.view" : "bills.view",
  );

  const [rows, currency] = await Promise.all([
    canView
      ? getSalesPurchaseReport({
          entity_id: membership.entity_id,
          side,
          dimension,
          start_date: range.from,
          end_date: range.to,
        })
      : Promise.resolve([]),
    getEntityBaseCurrency(membership.entity_id),
  ]);

  return (
    <>
      <SalesPurchaseScreen
        rows={rows}
        side={side}
        dimension={dimension}
        from={range.from}
        to={range.to}
        currency={currency}
        entity={params.entity}
        canView={canView}
      />
      <SaveReportForm
        entity={params.entity}
        path="/reports/sales-purchase"
        query={reportQueryToSave({ side, by: dimension, from: range.from, to: range.to })}
      />
    </>
  );
}
