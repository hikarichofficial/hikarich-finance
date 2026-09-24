import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getBpjsEnrolment,
  getCompensation,
  getEmploymentHistory,
  getEntityBaseCurrency,
  getTaxProfile,
  listEmployees,
} from "@/services/payroll/payroll";
import { EmployeeDetailScreen } from "@/features/payroll/EmployeeDetailScreen";

/** Employee Detail (P13 Part 3g, first increment, Step 09 §10, §17: "compensation is permission-gated").
 * No per-employee RPC returns the row itself (`employee_code`/`full_name`/`status`/dates/current employment) --
 * only `employee_list`, Entity-scoped -- so the page fetches the register for the active Entity and looks up
 * the one row by id, the same shape Account Detail already uses for `money_control`. An id belonging to a
 * different Entity, or one the caller cannot see (`payroll.employee_view` failed already, above), lands here
 * as "not found", never a cross-Entity leak. Compensation/BPJS (`payroll.compensation_view`) and the tax
 * profile (`payroll.tax_view`) are fetched only when the viewer's own membership holds that permission --
 * checked with `can()` against the already-loaded access snapshot, the same helper Journal Detail uses to
 * gate its action buttons, applied here to gate a data fetch instead. Skipping the fetch entirely (rather
 * than calling it and catching FORBIDDEN) keeps a viewer without the permission from ever triggering the
 * RPC's own denial, matching Step 09 §17's "isolated as a sensitive module" framing. */
export default async function EmployeeDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("payroll.employee_view", {
    entityCode: entity,
  });
  const entityId = membership.entity_id;

  const entries = await listEmployees({ entity_id: entityId, include_ended: true });
  const employee = entries.find((row) => row.id === id);
  if (!employee) notFound();

  const canViewCompensation = can(access, entityId, "payroll.compensation_view");
  const canViewTax = can(access, entityId, "payroll.tax_view");

  const [history, currency, compensation, bpjs, taxProfile] = await Promise.all([
    getEmploymentHistory(id),
    getEntityBaseCurrency(entityId),
    canViewCompensation ? getCompensation({ employee_id: id }) : Promise.resolve(null),
    canViewCompensation ? getBpjsEnrolment({ employee_id: id }) : Promise.resolve(null),
    canViewTax ? getTaxProfile({ employee_id: id }) : Promise.resolve(null),
  ]);

  const backHref = entity
    ? `/payroll/employees?entity=${encodeURIComponent(entity)}`
    : "/payroll/employees";

  return (
    <EmployeeDetailScreen
      employee={employee}
      history={history}
      compensation={compensation}
      bpjs={bpjs}
      taxProfile={taxProfile}
      currency={currency}
      backHref={backHref}
    />
  );
}
