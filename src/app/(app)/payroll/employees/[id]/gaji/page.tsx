import { notFound } from "next/navigation";
import { getCompensation } from "@/services/payroll/payroll";
import { loadEmployeeContext } from "@/features/payroll/employeeContext";
import { EmployeeShell } from "@/features/payroll/EmployeeShell";
import { CompensationTable } from "@/features/payroll/EmployeeSections";
import { CompensationForm } from "@/features/payroll/EmployeeForms";

/** Employee pay: current salary components, and the editor for a change from a date. */
export default async function EmployeePayPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const ctx = await loadEmployeeContext(id, entity);
  if (!ctx.canViewCompensation) notFound();
  const compensation = await getCompensation({ employee_id: id });

  return (
    <EmployeeShell
      employee={ctx.employee}
      entity={entity}
      active="gaji"
      showPay
      showTax={ctx.canViewTax}
      title="Gaji & Komponen"
      description="Komponen gaji yang berlaku saat ini. BPJS dan PPh 21 dihitung otomatis dari sini saat payroll dibuat."
    >
      <CompensationTable compensation={compensation} currency={ctx.currency} />
      {ctx.canEditCompensation ? (
        <>
          <h3 className="emp-subtitle">Ubah gaji atau tambah komponen</h3>
          <CompensationForm
            employeeId={id}
            current={compensation.components.map((c) => ({
              component: c.component,
              kind: c.kind,
              label: c.label,
              amount: c.amount,
              taxable: c.taxable,
              bpjsBase: c.bpjs_base,
            }))}
            today={ctx.today}
            currency={ctx.currency}
          />
        </>
      ) : null}
    </EmployeeShell>
  );
}
