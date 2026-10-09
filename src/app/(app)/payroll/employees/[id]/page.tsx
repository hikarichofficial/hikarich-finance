import { getBpjsEnrolment, getCompensation, getTaxProfile } from "@/services/payroll/payroll";
import { loadEmployeeContext, payrollHref } from "@/features/payroll/employeeContext";
import { EmployeeShell } from "@/features/payroll/EmployeeShell";
import {
  Checklist,
  EmployeeSummary,
  type ChecklistItem,
} from "@/features/payroll/EmployeeSections";
import { formatMoney } from "@/domain/money/format";

/** Employee overview: who they are and which areas are still to be filled in, each a link to its own page. */
export default async function EmployeeOverviewPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const ctx = await loadEmployeeContext(id, entity);
  const { employee, currency } = ctx;

  const [compensation, bpjs, taxProfile] = await Promise.all([
    ctx.canViewCompensation ? getCompensation({ employee_id: id }) : Promise.resolve(null),
    ctx.canViewCompensation ? getBpjsEnrolment({ employee_id: id }) : Promise.resolve(null),
    ctx.canViewTax ? getTaxProfile({ employee_id: id }) : Promise.resolve(null),
  ]);

  const base = `/payroll/employees/${id}`;
  const items: ChecklistItem[] = [];
  if (compensation) {
    const count = compensation.components.length;
    items.push({
      key: "gaji",
      title: "Gaji & komponen",
      done: count > 0,
      text:
        count > 0
          ? `${count} komponen, total penghasilan ${formatMoney(compensation.earnings_total, currency)}`
          : "Belum ada komponen gaji. Payroll tidak bisa dihitung tanpa ini.",
      href: payrollHref(`${base}/gaji`, entity),
    });
  }
  if (taxProfile) {
    const complete =
      taxProfile.recorded &&
      taxProfile.tax_id_status !== "unknown" &&
      taxProfile.ptkp_status !== "unknown";
    items.push({
      key: "pajak",
      title: "Data pajak",
      done: complete,
      text: complete
        ? `PTKP ${taxProfile.ptkp_status}`
        : "NPWP/NIK dan status PTKP belum lengkap. PPh 21 dihitung 0 dan ditandai sampai diisi.",
      href: payrollHref(`${base}/pajak`, entity),
    });
  }
  if (bpjs) {
    const count = bpjs.enrolled.length;
    items.push({
      key: "bpjs",
      title: "BPJS",
      done: count > 0,
      text: count > 0 ? `${count} program terdaftar` : "Belum ada kepesertaan BPJS.",
      href: payrollHref(`${base}/bpjs`, entity),
    });
  }

  return (
    <EmployeeShell
      employee={employee}
      entity={entity}
      active="ringkasan"
      showPay={ctx.canViewCompensation}
      showTax={ctx.canViewTax}
      title="Ringkasan"
    >
      <EmployeeSummary employee={employee} />
      {items.length > 0 ? (
        <>
          <h3 className="emp-subtitle">Kelengkapan data untuk payroll</h3>
          <Checklist items={items} />
        </>
      ) : null}
    </EmployeeShell>
  );
}
