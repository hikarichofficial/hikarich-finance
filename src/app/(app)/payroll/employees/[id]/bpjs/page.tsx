import { notFound } from "next/navigation";
import { getBpjsEnrolment } from "@/services/payroll/payroll";
import { loadEmployeeContext } from "@/features/payroll/employeeContext";
import { EmployeeShell } from "@/features/payroll/EmployeeShell";
import { BpjsTable } from "@/features/payroll/EmployeeSections";
import { BpjsForm } from "@/features/payroll/EmployeeForms";

/** Employee BPJS: the programs the person is enrolled in, and the package choice. */
export default async function EmployeeBpjsPage({
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
  const bpjs = await getBpjsEnrolment({ employee_id: id });

  return (
    <EmployeeShell
      employee={ctx.employee}
      entity={entity}
      active="bpjs"
      showPay
      showTax={ctx.canViewTax}
      title="BPJS"
      description="Pilih paket kepesertaan; iuran karyawan dan perusahaan dihitung otomatis dari gaji tiap bulan."
    >
      <BpjsTable bpjs={bpjs} />
      {ctx.canEditCompensation ? (
        <>
          <h3 className="emp-subtitle">Atur kepesertaan</h3>
          <BpjsForm
            employeeId={id}
            current={bpjs.enrolled.map((e) => ({
              component: e.component,
              rateKey: e.rate_key,
              memberRef: e.member_ref,
            }))}
            today={ctx.today}
          />
        </>
      ) : null}
    </EmployeeShell>
  );
}
