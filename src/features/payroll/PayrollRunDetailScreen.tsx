import type { ReactNode } from "react";
import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  COMPENSATION_KIND_LABELS,
  PAYROLL_PAYMENT_KIND_LABELS,
  describePayrollFlag,
  payrollPeriodName,
} from "@/domain/payroll/payroll";
import { payrollRunPaymentStatusBadge, payrollRunStatusBadge } from "@/domain/payroll/runList";
import type {
  PayrollAdjustmentRow,
  PayrollLine,
  PayrollPaymentRow,
  PayrollRunDetail,
} from "@/schemas/payroll";
import { formatShortDate } from "./format";

function money(value: string | null, currency: string): string {
  return value === null ? "—" : formatMoney(value, currency);
}

/**
 * Payroll Run Detail (P13 Part 3g, second increment, Step 09 §17's own period -> employees -> calculation ->
 * review -> approval -> post/pay -> close wizard). This component itself only reads; the
 * run's commands (calculate, adjust, submit, approve, return, discard, post, pay, close, reopen, correct) are
 * client forms the page builds by status and permission and passes in as `actionsPanel`. Follows the
 * same narrower "Standard Record Detail Pattern subset" as every other Part 3f/3g Detail screen: Header /
 * Ringkasan always render; Penyesuaian (adjustments) and Pembayaran (payments) sections only when the run has
 * any. `tax_allowance`/`pph21`/`tax_base`/`tax_calc` are null for a viewer without `payroll.tax_view` -- the
 * RPC's own doing (`payroll_run_get`/`payroll_run_lines` each check it row-by-row), not this screen's, shown
 * as "—" so a masked figure is never mistaken for an actual zero. `review_flags`/`info_flags` reuse
 * `describePayrollFlag` (P9, `@/domain/payroll/payroll`) rather than a second copy of the same flag vocabulary.
 *
 * On a narrow screen the Baris Gaji Karyawan / Penyesuaian / Pembayaran tables become stacked cards
 * (`record-table-stacked`, `globals.css`; P13 Part 5; Step 09 §23), the same way `PayrollRunRegisterScreen`
 * already does (decision 205) -- each table's own first column stays the unlabelled heading.
 */
export function PayrollRunDetailScreen({
  run,
  lines,
  adjustments,
  payments,
  currency,
  backHref,
  qs,
  actionsPanel,
}: {
  run: PayrollRunDetail;
  lines: readonly PayrollLine[];
  adjustments: readonly PayrollAdjustmentRow[];
  payments: readonly PayrollPaymentRow[];
  currency: string;
  backHref: string;
  qs: string;
  /** The command forms (client components) the page built for this status and this viewer. */
  actionsPanel?: ReactNode;
}) {
  const statusBadge = payrollRunStatusBadge(run.status);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke Proses Payroll</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{payrollPeriodName(run.period_start)}</p>
          <h1>{run.run_number}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
          {run.stale ? (
            <span className="status-badge status-badge-attention">Perlu Dihitung Ulang</span>
          ) : null}
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Periode</dt>
            <dd>
              {formatShortDate(run.period_start)} – {formatShortDate(run.period_end)}
            </dd>
          </div>
          <div>
            <dt>Tanggal Bayar</dt>
            <dd>{formatShortDate(run.pay_date)}</dd>
          </div>
          <div>
            <dt>Jumlah Karyawan</dt>
            <dd>{run.employee_count}</dd>
          </div>
          {run.review_count > 0 ? (
            <div>
              <dt>Perlu Ditinjau</dt>
              <dd>{run.review_count} baris</dd>
            </div>
          ) : null}
          <div>
            <dt>Gaji Bruto</dt>
            <dd>{formatMoney(run.gross_pay_total, currency)}</dd>
          </div>
          <div>
            <dt>Tunjangan Pajak</dt>
            <dd>{money(run.tax_allowance_total, currency)}</dd>
          </div>
          <div>
            <dt>BPJS Karyawan</dt>
            <dd>{formatMoney(run.employee_bpjs_total, currency)}</dd>
          </div>
          <div>
            <dt>BPJS Perusahaan</dt>
            <dd>{formatMoney(run.employer_bpjs_total, currency)}</dd>
          </div>
          <div>
            <dt>PPh 21</dt>
            <dd>{money(run.pph21_total, currency)}</dd>
          </div>
          <div>
            <dt>Dasar Pengenaan Pajak</dt>
            <dd>{money(run.tax_base_total, currency)}</dd>
          </div>
          <div>
            <dt>Gaji Bersih</dt>
            <dd>{formatMoney(run.net_pay_total, currency)}</dd>
          </div>
          <div>
            <dt>Gaji Bersih Terbayar</dt>
            <dd>{formatMoney(run.net_paid, currency)}</dd>
          </div>
          <div>
            <dt>BPJS Kesehatan</dt>
            <dd>
              {formatMoney(run.bpjs_kes_due, currency)} · terbayar{" "}
              {formatMoney(run.bpjs_kes_paid, currency)}
            </dd>
          </div>
          <div>
            <dt>BPJS Ketenagakerjaan</dt>
            <dd>
              {formatMoney(run.bpjs_tk_due, currency)} · terbayar{" "}
              {formatMoney(run.bpjs_tk_paid, currency)}
            </dd>
          </div>
          {Number(run.bpjs_paid) > Number(run.bpjs_kes_paid) + Number(run.bpjs_tk_paid) ? (
            <div>
              <dt>BPJS Terbayar (belum dipisah)</dt>
              <dd>{formatMoney(run.bpjs_paid, currency)}</dd>
            </div>
          ) : null}
          {run.calculated_at ? (
            <div>
              <dt>Terakhir Dihitung</dt>
              <dd>
                {formatShortDate(run.calculated_at.slice(0, 10))} (revisi {run.calc_version})
              </dd>
            </div>
          ) : null}
          {run.note ? (
            <div>
              <dt>Catatan</dt>
              <dd>{run.note}</dd>
            </div>
          ) : null}
          {run.correction_reason ? (
            <div>
              <dt>Alasan Koreksi</dt>
              <dd>{run.correction_reason}</dd>
            </div>
          ) : null}
          {run.journal_id ? (
            <div>
              <dt>Jurnal</dt>
              <dd>
                <Link href={`/accounting/journal/${run.journal_id}${qs}`}>Lihat →</Link>
              </dd>
            </div>
          ) : null}
          {run.reversal_journal_id ? (
            <div>
              <dt>Jurnal Pembalik</dt>
              <dd>
                <Link href={`/accounting/journal/${run.reversal_journal_id}${qs}`}>Lihat →</Link>
              </dd>
            </div>
          ) : null}
        </dl>
        {run.differences.length > 0 ? (
          <ul className="hint" style={{ marginTop: "0.75rem" }}>
            {run.differences.map((diff) => (
              <li key={diff.code}>{diff.text}</li>
            ))}
          </ul>
        ) : null}
      </section>

      {actionsPanel ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Tindakan</h2>
          </div>
          {actionsPanel}
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Baris Gaji Karyawan</h2>
        </div>
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Karyawan</th>
              <th scope="col" className="num">
                Gaji Bruto
              </th>
              <th scope="col" className="num">
                BPJS Karyawan
              </th>
              <th scope="col" className="num">
                PPh 21
              </th>
              <th scope="col" className="num">
                Gaji Bersih
              </th>
              <th scope="col" className="num">
                Terbayar
              </th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line) => (
              <tr key={line.line_id}>
                <td>
                  {line.employee_code} — {line.employee_name}
                  {line.review_flags.length > 0 ? (
                    <div>
                      {line.review_flags.map((flag) => (
                        <span key={flag} className="status-badge status-badge-attention">
                          {describePayrollFlag(flag)}
                        </span>
                      ))}
                    </div>
                  ) : null}
                  {line.info_flags.length > 0 ? (
                    <p className="hint">
                      {line.info_flags.map((flag) => describePayrollFlag(flag)).join(" ")}
                    </p>
                  ) : null}
                </td>
                <td className="num" data-label="Gaji Bruto">
                  {formatMoney(line.gross_pay, currency)}
                </td>
                <td className="num" data-label="BPJS Karyawan">
                  {formatMoney(line.bpjs_employee, currency)}
                </td>
                <td className="num" data-label="PPh 21">
                  {money(line.pph21, currency)}
                </td>
                <td className="num" data-label="Gaji Bersih">
                  {formatMoney(line.net_pay, currency)}
                </td>
                <td className="num" data-label="Terbayar">
                  {formatMoney(line.net_paid, currency)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </section>

      {adjustments.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Penyesuaian</h2>
          </div>
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Karyawan</th>
                <th scope="col">Jenis</th>
                <th scope="col">Label</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Kena Pajak</th>
              </tr>
            </thead>
            <tbody>
              {adjustments.map((adjustment) => (
                <tr key={adjustment.adjustment_id}>
                  <td>{adjustment.employee_code}</td>
                  <td data-label="Jenis">{COMPENSATION_KIND_LABELS[adjustment.kind]}</td>
                  <td data-label="Label">{adjustment.label}</td>
                  <td className="num" data-label="Jumlah">
                    {formatMoney(adjustment.amount, currency)}
                  </td>
                  <td data-label="Kena Pajak">{adjustment.taxable ? "Ya" : "Tidak"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ) : null}

      {payments.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Pembayaran</h2>
          </div>
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Nomor</th>
                <th scope="col">Jenis</th>
                <th scope="col">Tanggal</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Status</th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {payments.map((payment) => {
                const paymentBadge = payrollRunPaymentStatusBadge(payment.status);
                return (
                  <tr key={payment.payment_id}>
                    <td>{payment.payment_number}</td>
                    <td data-label="Jenis">{PAYROLL_PAYMENT_KIND_LABELS[payment.kind]}</td>
                    <td data-label="Tanggal">{formatShortDate(payment.payment_date)}</td>
                    <td className="num" data-label="Jumlah">
                      {formatMoney(payment.amount, currency)}
                    </td>
                    <td data-label="Status">
                      <span className={`status-badge status-badge-${paymentBadge.tone}`}>
                        {paymentBadge.text}
                      </span>
                    </td>
                    <td data-label="Jurnal">
                      <Link href={`/accounting/journal/${payment.journal_id}${qs}`}>Lihat →</Link>
                      {payment.reversal_journal_id ? (
                        <>
                          {" · "}
                          <Link href={`/accounting/journal/${payment.reversal_journal_id}${qs}`}>
                            Pembalik →
                          </Link>
                        </>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      ) : null}
    </div>
  );
}
