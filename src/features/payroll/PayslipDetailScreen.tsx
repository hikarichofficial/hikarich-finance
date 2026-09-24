import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  BPJS_COMPONENT_LABELS,
  COMPENSATION_KIND_LABELS,
  PAYROLL_TAX_MODE_LABELS,
  TAX_METHOD_LABELS,
  payrollPeriodName,
  type BpjsComponent,
} from "@/domain/payroll/payroll";
import { payslipStatusBadge } from "@/domain/payroll/payslipList";
import type { PayslipDetail } from "@/schemas/payroll";
import { formatShortDate } from "./format";

function bpjsRows(share: Readonly<Record<string, string>>): readonly [string, string][] {
  return Object.entries(share).filter(([, amount]) => amount !== "0");
}

/**
 * Payslip Detail (P13 Part 3g, third increment, Step 09 §17). `payroll_payslip_get` returns the payslip
 * exactly as it was issued (an immutable snapshot, `s.snapshot` -- not recomputed from the run's current
 * state), so unlike every other Detail screen so far there is nothing here that can go stale. Its tax section
 * is removed from the snapshot entirely for a viewer without `payroll.tax_view` (`s.snapshot - 'tax'`, the
 * jsonb key itself is absent) rather than present-with-null-fields the way Payroll Run Detail's own tax
 * columns are masked (decision 180) -- `detail.tax` is therefore optional (`z.object({...}).optional()`), and
 * this screen renders the whole Pajak section only when it is present, not per-field "—" placeholders.
 * `bpjs_employee`/`bpjs_employer` are each a `{component: amount}` record (only the components that actually
 * applied to this employee); `bpjsRows` drops zero-amount entries so a component the employee simply doesn't
 * have (e.g. no JP) is not shown as an explicit 0.
 */
export function PayslipDetailScreen({
  detail,
  currency,
  backHref,
}: {
  detail: PayslipDetail;
  currency: string;
  backHref: string;
}) {
  const statusBadge = payslipStatusBadge(detail.status);
  const bpjsEmployeeRows = bpjsRows(detail.bpjs_employee);
  const bpjsEmployerRows = bpjsRows(detail.bpjs_employer);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke Slip Gaji</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{payrollPeriodName(`${detail.period}-01`)}</p>
          <h1>{detail.payslip_number}</h1>
          <p className="record-detail-counterparty">
            {detail.employee.code} — {detail.employee.name}
          </p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Proses Penggajian</dt>
            <dd>
              {detail.run_number} (revisi {detail.revision})
            </dd>
          </div>
          <div>
            <dt>Tanggal Bayar</dt>
            <dd>{formatShortDate(detail.pay_date)}</dd>
          </div>
          <div>
            <dt>Diterbitkan</dt>
            <dd>{formatShortDate(detail.issued_at.slice(0, 10))}</dd>
          </div>
          {detail.voided_at ? (
            <div>
              <dt>Dibatalkan</dt>
              <dd>{formatShortDate(detail.voided_at.slice(0, 10))}</dd>
            </div>
          ) : null}
          {detail.void_reason ? (
            <div>
              <dt>Alasan Dibatalkan</dt>
              <dd>{detail.void_reason}</dd>
            </div>
          ) : null}
          <div>
            <dt>Gaji Bruto</dt>
            <dd>{formatMoney(detail.gross_pay, currency)}</dd>
          </div>
          <div>
            <dt>Gaji Bersih</dt>
            <dd>{formatMoney(detail.net_pay, currency)}</dd>
          </div>
          <div>
            <dt>Gaji Bersih Terbayar</dt>
            <dd>{formatMoney(detail.net_paid, currency)}</dd>
          </div>
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Komponen Gaji</h2>
        </div>
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Komponen</th>
              <th scope="col">Jenis</th>
              <th scope="col" className="num">
                Jumlah
              </th>
              <th scope="col">Kena Pajak</th>
              <th scope="col">Dasar BPJS</th>
            </tr>
          </thead>
          <tbody>
            {detail.components.map((component) => (
              <tr key={component.code}>
                <td>{component.label}</td>
                <td>{COMPENSATION_KIND_LABELS[component.kind]}</td>
                <td className="num">{formatMoney(component.amount, currency)}</td>
                <td>{component.taxable ? "Ya" : "Tidak"}</td>
                <td>{component.bpjs_base ? "Ya" : "Tidak"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {detail.adjustments.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Penyesuaian</h2>
          </div>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Jenis</th>
                <th scope="col">Label</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Kena Pajak</th>
              </tr>
            </thead>
            <tbody>
              {detail.adjustments.map((adjustment, index) => (
                <tr key={`${adjustment.label}-${index}`}>
                  <td>{COMPENSATION_KIND_LABELS[adjustment.kind]}</td>
                  <td>{adjustment.label}</td>
                  <td className="num">{formatMoney(adjustment.amount, currency)}</td>
                  <td>{adjustment.taxable ? "Ya" : "Tidak"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ) : null}

      {bpjsEmployeeRows.length > 0 || bpjsEmployerRows.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Rincian BPJS</h2>
          </div>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Program</th>
                <th scope="col" className="num">
                  Iuran Karyawan
                </th>
                <th scope="col" className="num">
                  Iuran Perusahaan
                </th>
              </tr>
            </thead>
            <tbody>
              {Object.keys(BPJS_COMPONENT_LABELS)
                .filter(
                  (component) =>
                    detail.bpjs_employee[component] !== undefined ||
                    detail.bpjs_employer[component] !== undefined,
                )
                .map((component) => (
                  <tr key={component}>
                    <td>{BPJS_COMPONENT_LABELS[component as BpjsComponent]}</td>
                    <td className="num">
                      {detail.bpjs_employee[component]
                        ? formatMoney(detail.bpjs_employee[component], currency)
                        : "—"}
                    </td>
                    <td className="num">
                      {detail.bpjs_employer[component]
                        ? formatMoney(detail.bpjs_employer[component], currency)
                        : "—"}
                    </td>
                  </tr>
                ))}
            </tbody>
          </table>
        </section>
      ) : null}

      {detail.tax ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Pajak</h2>
          </div>
          <dl className="record-summary-grid">
            {detail.tax.mode ? (
              <div>
                <dt>Metode Tarif</dt>
                <dd>{PAYROLL_TAX_MODE_LABELS[detail.tax.mode]}</dd>
              </div>
            ) : null}
            {detail.tax.method ? (
              <div>
                <dt>Metode Penanggungan</dt>
                <dd>{TAX_METHOD_LABELS[detail.tax.method]}</dd>
              </div>
            ) : null}
            <div>
              <dt>Dasar Pengenaan Pajak</dt>
              <dd>{formatMoney(detail.tax.base, currency)}</dd>
            </div>
            <div>
              <dt>PPh 21</dt>
              <dd>{formatMoney(detail.tax.pph21, currency)}</dd>
            </div>
            <div>
              <dt>Tunjangan Pajak</dt>
              <dd>{formatMoney(detail.tax.allowance, currency)}</dd>
            </div>
            <div>
              <dt>Dipotong dari Karyawan</dt>
              <dd>{formatMoney(detail.tax.withheld_from_employee, currency)}</dd>
            </div>
          </dl>
        </section>
      ) : null}
    </div>
  );
}
