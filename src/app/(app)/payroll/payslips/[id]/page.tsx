import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { requireAccess } from "@/services/identity/access";
import { getEntityBaseCurrency, getPayslip } from "@/services/payroll/payroll";
import { PayslipDetailScreen } from "@/features/payroll/PayslipDetailScreen";

/**
 * Payslip Detail (P13 Part 3g, third increment, Step 09 §17). Same compound-permission rule as the Register
 * page and every Payroll Run screen (decision 180): `payroll.compensation_view` AND at least one of
 * `payroll.run`/`payroll.approve`/`payroll.pay`. `getPayslip` is caught rather than let through: a
 * nonexistent payslip id reaches the database as a null-entity row, which `payroll_read_authorize` turns into
 * `FORBIDDEN` (not a distinct not-found signal) -- the same forgiving catch-all `.catch(() => null)` +
 * `notFound()` every other Detail page already uses.
 */
export default async function PayslipDetailPage({
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

  const detail = await getPayslip(id).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(entityId);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `/payroll/payslips${qs}`;

  return <PayslipDetailScreen detail={detail} currency={currency} backHref={backHref} />;
}
