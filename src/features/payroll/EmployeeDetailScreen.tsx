import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  BPJS_COMPONENT_LABELS,
  COMPENSATION_KIND_LABELS,
  EMPLOYMENT_TYPE_LABELS,
  TAX_ID_STATUS_LABELS,
  TAX_METHOD_LABELS,
} from "@/domain/payroll/payroll";
import { employeeStatusBadge } from "@/domain/payroll/employeeList";
import type {
  BpjsEnrolment,
  Compensation,
  EmployeeRow,
  EmploymentHistoryRow,
  TaxProfile,
} from "@/schemas/payroll";
import { formatShortDate } from "./format";

/**
 * Employee Detail (P13 Part 3g, first increment, Step 09 §10, §17: "compensation is permission-gated").
 * Follows the same narrower "Standard Record Detail Pattern subset" every other Part 3 Detail screen uses
 * (decision 169's precedent): Header / Ringkasan / Riwayat Jabatan always render; Kompensasi and BPJS render
 * only when `compensation`/`bpjs` are non-null (the page fetches them only when the viewer holds
 * `payroll.compensation_view`, the exact permission `employee_compensation_get`/`employee_bpjs_get` check),
 * and Pajak only when `taxProfile` is non-null (`payroll.tax_view`, `employee_tax_profile_get`). A viewer
 * without either permission sees the sections omitted entirely, not a placeholder or an error -- the same
 * "isolated as a sensitive module" reading Step 09 §17 asks for. The full (unmasked) tax identifier
 * (`employee_tax_identifier`, needs a fresh step-up) is deferred: nothing on this read-only screen needs it
 * yet, and `taxProfile.tax_id_masked` already covers what a Detail screen shows day to day.
 */
export function EmployeeDetailScreen({
  employee,
  history,
  compensation,
  bpjs,
  taxProfile,
  currency,
  backHref,
}: {
  employee: EmployeeRow;
  history: readonly EmploymentHistoryRow[];
  compensation: Compensation | null;
  bpjs: BpjsEnrolment | null;
  taxProfile: TaxProfile | null;
  currency: string;
  backHref: string;
}) {
  const statusBadge = employeeStatusBadge(employee.status);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar karyawan</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Karyawan · {employee.employee_code}</p>
          <h1>{employee.full_name}</h1>
          <p className="record-detail-counterparty">{employee.position_title}</p>
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
            <dt>Tanggal Masuk</dt>
            <dd>{formatShortDate(employee.join_date)}</dd>
          </div>
          {employee.exit_date ? (
            <div>
              <dt>Tanggal Berhenti</dt>
              <dd>{formatShortDate(employee.exit_date)}</dd>
            </div>
          ) : null}
          <div>
            <dt>Jenis Karyawan</dt>
            <dd>{EMPLOYMENT_TYPE_LABELS[employee.employment_type]}</dd>
          </div>
          <div>
            <dt>Jabatan</dt>
            <dd>{employee.position_title}</dd>
          </div>
          <div>
            <dt>Departemen</dt>
            <dd>{employee.department ?? "—"}</dd>
          </div>
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Jabatan</h2>
        </div>
        {history.length === 0 ? (
          <p className="dashboard-empty">Belum ada riwayat jabatan.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Berlaku Sejak</th>
                <th scope="col">Jenis</th>
                <th scope="col">Jabatan</th>
                <th scope="col">Departemen</th>
                <th scope="col">Catatan</th>
              </tr>
            </thead>
            <tbody>
              {history.map((line) => (
                <tr key={line.effective_from}>
                  <td>{formatShortDate(line.effective_from)}</td>
                  <td>{EMPLOYMENT_TYPE_LABELS[line.employment_type]}</td>
                  <td>{line.position_title}</td>
                  <td>{line.department ?? "—"}</td>
                  <td>{line.note ?? "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {compensation ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Kompensasi</h2>
          </div>
          <dl className="record-summary-grid">
            <div>
              <dt>Total Penghasilan</dt>
              <dd>{formatMoney(compensation.earnings_total, currency)}</dd>
            </div>
            <div>
              <dt>Total Potongan</dt>
              <dd>{formatMoney(compensation.deductions_total, currency)}</dd>
            </div>
          </dl>
          {compensation.components.length === 0 ? (
            <p className="dashboard-empty">Belum ada komponen gaji.</p>
          ) : (
            <table className="record-table">
              <thead>
                <tr>
                  <th scope="col">Komponen</th>
                  <th scope="col">Jenis</th>
                  <th scope="col" className="num">
                    Jumlah
                  </th>
                  <th scope="col">Berlaku Sejak</th>
                </tr>
              </thead>
              <tbody>
                {compensation.components.map((c) => (
                  <tr key={c.component}>
                    <td>{c.label}</td>
                    <td>{COMPENSATION_KIND_LABELS[c.kind]}</td>
                    <td className="num">{formatMoney(c.amount, currency)}</td>
                    <td>{formatShortDate(c.effective_from)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {bpjs ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">BPJS</h2>
          </div>
          {bpjs.enrolled.length === 0 ? (
            <p className="dashboard-empty">Belum terdaftar BPJS.</p>
          ) : (
            <table className="record-table">
              <thead>
                <tr>
                  <th scope="col">Program</th>
                  <th scope="col">Nomor Anggota</th>
                  <th scope="col">Berlaku Sejak</th>
                </tr>
              </thead>
              <tbody>
                {bpjs.enrolled.map((e) => (
                  <tr key={e.component}>
                    <td>{BPJS_COMPONENT_LABELS[e.component]}</td>
                    <td>{e.member_ref ?? "—"}</td>
                    <td>{formatShortDate(e.effective_from)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {taxProfile ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Pajak</h2>
          </div>
          {taxProfile.recorded ? (
            <dl className="record-summary-grid">
              <div>
                <dt>Status NPWP/NIK</dt>
                <dd>{TAX_ID_STATUS_LABELS[taxProfile.tax_id_status]}</dd>
              </div>
              {taxProfile.tax_id_masked ? (
                <div>
                  <dt>Nomor (disamarkan)</dt>
                  <dd>{taxProfile.tax_id_masked}</dd>
                </div>
              ) : null}
              <div>
                <dt>Status PTKP</dt>
                <dd>{taxProfile.ptkp_status}</dd>
              </div>
              <div>
                <dt>Metode Pajak</dt>
                <dd>{TAX_METHOD_LABELS[taxProfile.tax_method]}</dd>
              </div>
            </dl>
          ) : (
            <p className="dashboard-empty">Data pajak belum dicatat.</p>
          )}
        </section>
      ) : null}
    </div>
  );
}
