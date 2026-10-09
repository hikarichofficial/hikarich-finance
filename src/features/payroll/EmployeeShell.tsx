import Link from "next/link";
import type { ReactNode } from "react";
import { employeeStatusBadge } from "@/domain/payroll/employeeList";
import type { EmployeeRow } from "@/schemas/payroll";
import { BackLink } from "@/features/shell/BackLink";
import { payrollHref } from "./employeeContext";

export type EmployeeTab = "ringkasan" | "gaji" | "pajak" | "bpjs" | "pekerjaan";

/**
 * The frame every employee page shares (OWNER, 9 October 2026): the person's name and status on top and one tab
 * per area, each tab its own page with its own address, instead of one long page of buttons that open forms.
 * Same pattern as the HR/payroll products it was modelled on (Gusto, Mekari Talenta): a profile header, then
 * "Ringkasan", pay, tax, BPJS and job as separate sections.
 */
export function EmployeeShell({
  employee,
  entity,
  active,
  showPay,
  showTax,
  title,
  description,
  children,
}: {
  employee: EmployeeRow;
  entity: string | undefined;
  active: EmployeeTab;
  /** `payroll.compensation_view`: the Gaji and BPJS tabs. */
  showPay: boolean;
  /** `payroll.tax_view`: the Pajak tab. */
  showTax: boolean;
  /** The heading of the section this page is. */
  title: string;
  description?: string;
  children: ReactNode;
}) {
  const badge = employeeStatusBadge(employee.status);
  const base = `/payroll/employees/${employee.id}`;
  const tabs: { key: EmployeeTab; label: string; href: string; visible: boolean }[] = [
    { key: "ringkasan", label: "Ringkasan", href: base, visible: true },
    { key: "gaji", label: "Gaji & Komponen", href: `${base}/gaji`, visible: showPay },
    { key: "pajak", label: "Pajak", href: `${base}/pajak`, visible: showTax },
    { key: "bpjs", label: "BPJS", href: `${base}/bpjs`, visible: showPay },
    { key: "pekerjaan", label: "Pekerjaan", href: `${base}/pekerjaan`, visible: true },
  ];

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={payrollHref("/payroll/employees", entity)}>
          ← Kembali ke daftar karyawan
        </BackLink>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Karyawan · {employee.employee_code}</p>
          <h1>{employee.full_name}</h1>
          <p className="record-detail-counterparty">{employee.position_title}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
        </div>
      </header>

      <nav className="emp-tabs" aria-label="Bagian data karyawan">
        {tabs
          .filter((tab) => tab.visible)
          .map((tab) => (
            <Link
              key={tab.key}
              href={payrollHref(tab.href, entity)}
              className={tab.key === active ? "emp-tab emp-tab-active" : "emp-tab"}
              aria-current={tab.key === active ? "page" : undefined}
            >
              {tab.label}
            </Link>
          ))}
      </nav>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">{title}</h2>
        </div>
        {description ? <p className="hint emp-lead">{description}</p> : null}
        {children}
      </section>
    </div>
  );
}
