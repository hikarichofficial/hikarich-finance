import { getEmploymentHistory } from "@/services/payroll/payroll";
import { loadEmployeeContext } from "@/features/payroll/employeeContext";
import { EmployeeShell } from "@/features/payroll/EmployeeShell";
import { EmployeeSummary, HistoryTable } from "@/features/payroll/EmployeeSections";
import {
  EmploymentForm,
  EndEmployeeForm,
  UpdateEmployeeForm,
} from "@/features/payroll/EmployeeForms";

/** Employee job: personal data, position history, and leaving the company. */
export default async function EmployeeJobPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const ctx = await loadEmployeeContext(id, entity);
  const { employee } = ctx;
  const history = await getEmploymentHistory(id);

  return (
    <EmployeeShell
      employee={employee}
      entity={entity}
      active="pekerjaan"
      showPay={ctx.canViewCompensation}
      showTax={ctx.canViewTax}
      title="Pekerjaan"
    >
      <EmployeeSummary employee={employee} />
      <h3 className="emp-subtitle">Riwayat jabatan</h3>
      <HistoryTable history={history} />
      {ctx.canEdit ? (
        <>
          <h3 className="emp-subtitle">Catat perubahan jabatan</h3>
          <EmploymentForm
            employeeId={id}
            employmentType={employee.employment_type}
            positionTitle={employee.position_title}
            department={employee.department}
            today={ctx.today}
          />
          <h3 className="emp-subtitle">Ubah data karyawan</h3>
          <UpdateEmployeeForm
            employeeId={id}
            fullName={employee.full_name}
            joinDate={employee.join_date}
          />
          {employee.status === "active" ? (
            <>
              <h3 className="emp-subtitle">Karyawan berhenti</h3>
              <EndEmployeeForm employeeId={id} today={ctx.today} />
            </>
          ) : null}
        </>
      ) : null}
    </EmployeeShell>
  );
}
