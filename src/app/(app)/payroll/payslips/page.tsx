import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { filterPayslipRows, parsePayslipStatusFilter } from "@/domain/payroll/payslipList";
import { requireAccess } from "@/services/identity/access";
import { getEntityBaseCurrency, listPayslips } from "@/services/payroll/payroll";
import { PayslipRegisterScreen } from "@/features/payroll/PayslipRegisterScreen";

/**
 * Payslip Register (P13 Part 3g, third increment, Step 09 §17). `payroll_payslip_list` shares the exact same
 * compound authorize rule as the Payroll Run screens (decision 180): `payroll.compensation_view` AND at least
 * one of `payroll.run`/`payroll.approve`/`payroll.pay` (confirmed against
 * `20260927100700_p9_payroll_reports.sql`), so this page uses the same `requireAccess` + manual `can()` check
 * rather than `requirePermission`.
 */
export default async function PayslipRegisterPage({
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

  const payslipStatus = parsePayslipStatusFilter(status) ?? null;
  const query = q ?? "";

  const [payslips, currency] = await Promise.all([
    listPayslips({ entity_id: entityId }),
    getEntityBaseCurrency(entityId),
  ]);
  const rows = filterPayslipRows(payslips, payslipStatus, query);

  return (
    <PayslipRegisterScreen
      rows={rows}
      status={payslipStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
