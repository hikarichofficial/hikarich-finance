import { requirePermission } from "@/services/identity/access";
import { EmployeeForm } from "@/features/payroll/EmployeeForm";
import { todayInBusinessZone } from "@/lib/time";
import { BackLink } from "@/features/shell/BackLink";

/** Tambah Karyawan, gated `payroll.employee_edit` -- the permission `employee_create` itself checks. */
export default async function NewEmployeePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  await requirePermission("payroll.employee_edit", { entityCode: entity });
  const backHref = entity
    ? `/payroll/employees?entity=${encodeURIComponent(entity)}`
    : "/payroll/employees";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar karyawan</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Payroll</p>
          <h1>Tambah Karyawan</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <EmployeeForm entity={entity} today={todayInBusinessZone()} />
      </section>
    </div>
  );
}
