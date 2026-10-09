import { notFound } from "next/navigation";
import { getTaxProfile } from "@/services/payroll/payroll";
import { loadEmployeeContext } from "@/features/payroll/employeeContext";
import { EmployeeShell } from "@/features/payroll/EmployeeShell";
import { TaxProfileCard } from "@/features/payroll/EmployeeSections";
import { TaxOpeningForm, TaxProfileForm } from "@/features/payroll/EmployeeForms";

/** Employee tax: NPWP/NIK, PTKP and method, plus the opening balance for someone paid before this app. */
export default async function EmployeeTaxPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const ctx = await loadEmployeeContext(id, entity);
  if (!ctx.canViewTax) notFound();
  const taxProfile = await getTaxProfile({ employee_id: id });

  // The opening balance only matters for someone paid before this app was used: from February on, and not for
  // an employee who joined this month (nothing could have been paid before it). Otherwise it is not offered.
  const month = Number(ctx.today.slice(5, 7));
  const showTaxOpening =
    ctx.canSetTaxOpening && month >= 2 && ctx.employee.join_date < `${ctx.today.slice(0, 7)}-01`;

  return (
    <EmployeeShell
      employee={ctx.employee}
      entity={entity}
      active="pajak"
      showPay={ctx.canViewCompensation}
      showTax
      title="Pajak"
      description="Status NPWP/NIK dan PTKP menentukan PPh 21 bulanan. Selama belum lengkap, PPh 21 dihitung 0 dan payroll diberi tanda."
    >
      <TaxProfileCard taxProfile={taxProfile} />
      {ctx.canEditTax ? (
        <>
          <h3 className="emp-subtitle">Ubah data pajak</h3>
          <TaxProfileForm
            employeeId={id}
            current={
              taxProfile.recorded
                ? {
                    taxIdStatus: taxProfile.tax_id_status,
                    ptkpStatus: taxProfile.ptkp_status,
                    taxMethod: taxProfile.tax_method,
                  }
                : null
            }
            today={ctx.today}
          />
        </>
      ) : null}
      {showTaxOpening ? (
        <>
          <h3 className="emp-subtitle">Saldo awal pajak (hanya karyawan lama)</h3>
          <TaxOpeningForm
            employeeId={id}
            year={Number(ctx.today.slice(0, 4))}
            defaultMonth={Math.min(11, Math.max(1, month - 1))}
          />
        </>
      ) : null}
    </EmployeeShell>
  );
}
