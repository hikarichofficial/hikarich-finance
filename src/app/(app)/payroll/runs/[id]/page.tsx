import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { requireAccess } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getPayrollLines,
  getPayrollRun,
  listPayrollAdjustments,
  listPayrollPayments,
} from "@/services/payroll/payroll";
import { PayrollRunDetailScreen } from "@/features/payroll/PayrollRunDetailScreen";

/**
 * Payroll Run Detail (P13 Part 3g, second increment, Step 09 §17). Same compound-permission rule as the
 * Register page (`payroll.compensation_view` AND at least one of `payroll.run`/`payroll.approve`/`payroll.pay`,
 * confirmed against `20260927100700_p9_payroll_reports.sql`'s own `app_private.payroll_read_authorize`), so
 * `requireAccess` + a manual `can()` check stands in for `requirePermission` here too. `getPayrollRun` is
 * caught rather than let through: a nonexistent run id reaches the database as a null-entity row, which
 * `payroll_read_authorize` itself turns into `FORBIDDEN` (not a distinct not-found signal) -- the same
 * forgiving catch-all `.catch(() => null)` + `notFound()` every other Detail page already uses (Equity Detail,
 * Loan Detail, Account Detail) means a cross-Entity or missing id reads identically as "not found" either way.
 */
export default async function PayrollRunDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;

  const canRead =
    can(access, entityId, "payroll.compensation_view") &&
    (can(access, entityId, "payroll.run") ||
      can(access, entityId, "payroll.approve") ||
      can(access, entityId, "payroll.pay"));
  if (!canRead) throw new AuthzError("FORBIDDEN");

  const run = await getPayrollRun(id).catch(() => null);
  if (!run) notFound();

  const [lines, adjustments, payments, currency] = await Promise.all([
    getPayrollLines(id),
    listPayrollAdjustments(id),
    listPayrollPayments(id),
    getEntityBaseCurrency(entityId),
  ]);

  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `/payroll/runs${qs}`;

  return (
    <PayrollRunDetailScreen
      run={run}
      lines={lines}
      adjustments={adjustments}
      payments={payments}
      currency={currency}
      backHref={backHref}
      qs={qs}
    />
  );
}
