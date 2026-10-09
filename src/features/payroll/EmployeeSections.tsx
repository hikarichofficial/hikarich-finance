import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  BPJS_COMPONENT_LABELS,
  COMPENSATION_KIND_LABELS,
  EMPLOYMENT_TYPE_LABELS,
  TAX_ID_STATUS_LABELS,
  TAX_METHOD_LABELS,
} from "@/domain/payroll/payroll";
import type {
  BpjsEnrolment,
  Compensation,
  EmployeeRow,
  EmploymentHistoryRow,
  TaxProfile,
} from "@/schemas/payroll";
import { formatShortDate } from "./format";

/** The read-only blocks the employee pages show above their forms. */

export function EmployeeSummary({ employee }: { employee: EmployeeRow }) {
  return (
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
  );
}

export function HistoryTable({ history }: { history: readonly EmploymentHistoryRow[] }) {
  if (history.length === 0) return <p className="dashboard-empty">Belum ada riwayat jabatan.</p>;
  return (
    <table className="record-table record-table-stacked">
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
            <td data-label="Jenis">{EMPLOYMENT_TYPE_LABELS[line.employment_type]}</td>
            <td data-label="Jabatan">{line.position_title}</td>
            <td data-label="Departemen">{line.department ?? "—"}</td>
            <td data-label="Catatan">{line.note ?? "—"}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function CompensationTable({
  compensation,
  currency,
}: {
  compensation: Compensation;
  currency: string;
}) {
  return (
    <>
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
        <table className="record-table record-table-stacked">
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
                <td data-label="Jenis">{COMPENSATION_KIND_LABELS[c.kind]}</td>
                <td className="num" data-label="Jumlah">
                  {formatMoney(c.amount, currency)}
                </td>
                <td data-label="Berlaku Sejak">{formatShortDate(c.effective_from)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </>
  );
}

export function BpjsTable({ bpjs }: { bpjs: BpjsEnrolment }) {
  if (bpjs.enrolled.length === 0) return <p className="dashboard-empty">Belum terdaftar BPJS.</p>;
  return (
    <table className="record-table record-table-stacked">
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
            <td data-label="Nomor Anggota">{e.member_ref ?? "—"}</td>
            <td data-label="Berlaku Sejak">{formatShortDate(e.effective_from)}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export function TaxProfileCard({ taxProfile }: { taxProfile: TaxProfile }) {
  if (!taxProfile.recorded) return <p className="dashboard-empty">Data pajak belum dicatat.</p>;
  return (
    <dl className="record-summary-grid">
      <div>
        <dt>Status NPWP/NIK</dt>
        <dd>{TAX_ID_STATUS_LABELS[taxProfile.tax_id_status]}</dd>
      </div>
      {taxProfile.tax_id_masked ? (
        <div>
          <dt>NPWP/NIK untuk pajak (disamarkan)</dt>
          <dd>{taxProfile.tax_id_masked}</dd>
        </div>
      ) : null}
      {taxProfile.national_id_masked ? (
        <div>
          <dt>NIK (disamarkan)</dt>
          <dd>{taxProfile.national_id_masked}</dd>
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
  );
}

export interface ChecklistItem {
  key: string;
  title: string;
  /** Short result: what is set, or what is missing. */
  text: string;
  done: boolean;
  href: string;
}

/** "What is still missing" on the overview: one card per area, each a link to its own page. */
export function Checklist({ items }: { items: readonly ChecklistItem[] }) {
  return (
    <ul className="emp-checklist">
      {items.map((item) => (
        <li key={item.key}>
          <Link href={item.href} className="emp-check" data-done={item.done}>
            <span className="emp-check-mark" aria-hidden="true">
              {item.done ? "✓" : "!"}
            </span>
            <span className="emp-check-body">
              <strong>{item.title}</strong>
              <span>{item.text}</span>
            </span>
            <span className="emp-check-go" aria-hidden="true">
              {item.done ? "Lihat" : "Lengkapi"} →
            </span>
          </Link>
        </li>
      ))}
    </ul>
  );
}
