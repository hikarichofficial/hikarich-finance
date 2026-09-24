import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { filterPayrollRunRows, parsePayrollRunStatusFilter } from "@/domain/payroll/runList";
import { requireAccess } from "@/services/identity/access";
import { getEntityBaseCurrency, listPayrollRuns } from "@/services/payroll/payroll";
import { PayrollRunRegisterScreen } from "@/features/payroll/PayrollRunRegisterScreen";

/**
 * Payroll Run Register (P13 Part 3g, second increment, Step 09 §17). Unlike Employee Register/Detail
 * (`payroll.employee_view`, decision 179), `payroll_run_list`'s own authorize call
 * (`app_private.payroll_read_authorize`, confirmed directly against `20260927100700_p9_payroll_reports.sql`)
 * needs BOTH `payroll.compensation_view` AND at least one of `payroll.run` / `payroll.approve` / `payroll.pay`
 * -- a compound rule `requirePermission`'s single-permission-string check cannot express. This page calls
 * `requireAccess` directly and asserts the same compound rule with `can()`, throwing the identical
 * `AuthzError("FORBIDDEN")` `assertCan` would throw for a single permission, so the failure mode every other
 * protected page already has (an uncaught `AuthzError`, no dedicated 403 screen exists yet anywhere in this
 * codebase) is unchanged here.
 */
export default async function PayrollRunRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;

  const canRead =
    can(access, entityId, "payroll.compensation_view") &&
    (can(access, entityId, "payroll.run") ||
      can(access, entityId, "payroll.approve") ||
      can(access, entityId, "payroll.pay"));
  if (!canRead) throw new AuthzError("FORBIDDEN");

  const runStatus = parsePayrollRunStatusFilter(status) ?? null;
  const query = q ?? "";

  const [runs, currency] = await Promise.all([
    listPayrollRuns({ entity_id: entityId, status: runStatus ?? undefined }),
    getEntityBaseCurrency(entityId),
  ]);
  const rows = filterPayrollRunRows(runs, query);

  return (
    <PayrollRunRegisterScreen
      rows={rows}
      status={runStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
