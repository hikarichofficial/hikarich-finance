import { cache } from "react";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listEmployees } from "@/services/payroll/payroll";
import { todayInBusinessZone } from "@/lib/time";

/**
 * What every employee sub-page needs, loaded once per request (`cache`): the employee row, the viewer's
 * permissions and the entity query string for links. As before the screen was split (P13 Part 3g), no
 * per-employee RPC returns the row itself, so the register of the active Entity is read and the one row looked
 * up by id: an id from another Entity, or one the caller cannot see, is "not found", never a cross-Entity leak.
 * Compensation/BPJS need `payroll.compensation_view`, the tax profile `payroll.tax_view`; the write forms need
 * the permission each RPC checks (`payroll.employee_edit`, `payroll.compensation_edit`).
 */
export const loadEmployeeContext = cache(async (id: string, entity: string | undefined) => {
  const { access, membership } = await requirePermission("payroll.employee_view", {
    entityCode: entity,
  });
  const entityId = membership.entity_id;
  const entries = await listEmployees({ entity_id: entityId, include_ended: true });
  const employee = entries.find((row) => row.id === id);
  if (!employee) notFound();

  const canViewCompensation = can(access, entityId, "payroll.compensation_view");
  const canViewTax = can(access, entityId, "payroll.tax_view");
  const canEdit = can(access, entityId, "payroll.employee_edit");
  const canEditCompensation = can(access, entityId, "payroll.compensation_edit");

  return {
    employee,
    entityId,
    entity,
    currency: await getEntityBaseCurrency(entityId),
    today: todayInBusinessZone(),
    canViewCompensation,
    canViewTax,
    canEdit,
    canEditCompensation,
    canEditTax: canEdit && canViewTax,
    canSetTaxOpening: canEditCompensation && canViewCompensation && canViewTax,
  };
});

export type EmployeeContext = Awaited<ReturnType<typeof loadEmployeeContext>>;

/** A link inside the Payroll area that keeps the active Entity (`?entity=`). */
export function payrollHref(path: string, entity: string | undefined): string {
  return entity ? `${path}?entity=${encodeURIComponent(entity)}` : path;
}
