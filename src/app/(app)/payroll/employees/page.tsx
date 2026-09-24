import { requirePermission } from "@/services/identity/access";
import { listEmployees } from "@/services/payroll/payroll";
import {
  filterEmployeeRows,
  parseEmployeeStatusFilter,
  parseEmploymentTypeFilter,
} from "@/domain/payroll/employeeList";
import { EmployeeRegisterScreen } from "@/features/payroll/EmployeeRegisterScreen";

/** Employee Register (P13 Part 3g, first increment, Step 09 §9, §17). `status`/`type` are client-side
 * refinements on top of `employee_list`'s own `p_include_ended` (always requested `true` here, so ended
 * employees stay visible and filterable rather than disappearing from the register); `?q=` is a client-side
 * code/name/position/department search. */
export default async function EmployeeRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; type?: string; q?: string }>;
}) {
  const { entity, status, type, q } = await searchParams;
  const { membership } = await requirePermission("payroll.employee_view", { entityCode: entity });
  const employeeStatus = parseEmployeeStatusFilter(status) ?? null;
  const employmentType = parseEmploymentTypeFilter(type) ?? null;
  const query = q ?? "";

  const entries = await listEmployees({ entity_id: membership.entity_id, include_ended: true });
  const rows = filterEmployeeRows(entries, employeeStatus, employmentType, query);

  return (
    <EmployeeRegisterScreen
      rows={rows}
      status={employeeStatus}
      employmentType={employmentType}
      query={query}
      entity={entity}
    />
  );
}
