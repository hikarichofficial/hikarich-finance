import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { PAYROLL_LIABILITY_LABELS, payrollPeriodName } from "@/domain/payroll/payroll";
import {
  TAX_LEDGER_SOURCE_LABELS,
  annualReconciliationStatusBadge,
  certificateHref,
  pph21DepositHref,
} from "@/domain/payroll/taxLiabilities";
import type {
  AnnualReconciliationRow,
  PayrollLiabilityRow,
  TaxLedgerRow,
  WithholdingCertificateRow,
} from "@/schemas/payroll";
import { formatShortDate } from "./format";

function money(value: string | null, currency: string): string {
  return value === null ? "—" : formatMoney(value, currency);
}

/**
 * Payroll Tax & Liabilities (P13 Part 3g, fourth increment, Step 09 §17). Three report RPCs, one screen, the
 * same "filter bar + summary + table" report shape the Depreciation report (decision 178) already
 * established, extended here to several independently-filtered sections rather than one. Kewajiban
 * Pembayaran (Payroll Liabilities) always renders -- `payroll_liability_report` needs only the base compound
 * permission (decision 180), and its own `pph21` rows are simply absent for a viewer without
 * `payroll.tax_view` (the RPC's own doing). Rekonsiliasi Tahunan (Annual Reconciliation) and Buku Besar Pajak
 * Karyawan (Employee Tax Ledger) render only when the viewer holds `payroll.tax_view` -- both RPCs raise a
 * hard `FORBIDDEN` without it (unlike Liabilities' own row-omission), so the page skips the fetch entirely,
 * the same "gate the fetch, not just the section" precedent decision 179/181 already established.
 * `payroll_summary_report`/`payroll_control_report` are deferred (see `taxLiabilities.ts`'s own doc comment).
 *
 * On a narrow screen the three tables become stacked cards (`record-table-stacked`, `globals.css`; P13 Part
 * 5; Step 09 §23), each keeping its own first column as the unlabelled heading -- these are per-row
 * liability/reconciliation/ledger lines, not a period-by-period comparison, so they are not the kind of
 * columnar table decision 202/207 excludes.
 */
export function PayrollTaxScreen({
  liabilities,
  reconciliation,
  certificates,
  taxLedger,
  asOf,
  year,
  currency,
  entity,
  canViewTax,
}: {
  liabilities: readonly PayrollLiabilityRow[];
  reconciliation: readonly AnnualReconciliationRow[] | null;
  certificates: readonly WithholdingCertificateRow[] | null;
  taxLedger: readonly TaxLedgerRow[] | null;
  asOf: string;
  year: number;
  currency: string;
  entity: string | undefined;
  canViewTax: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Pajak & Kewajiban Payroll</h1>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Per Tanggal
            <input type="date" name="as_of" defaultValue={asOf} />
          </label>
          {canViewTax ? (
            <label>
              Tahun Pajak
              <input type="number" name="year" defaultValue={year} min={2000} max={2100} />
            </label>
          ) : null}
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Kewajiban Pembayaran</h2>
        </div>
        {liabilities.length === 0 ? (
          <div className="list-empty">
            <p>Tidak ada kewajiban pada tanggal ini.</p>
          </div>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Jenis</th>
                <th scope="col">Periode</th>
                <th scope="col">Proses</th>
                <th scope="col" className="num">
                  Terutang
                </th>
                <th scope="col" className="num">
                  Dibayar
                </th>
                <th scope="col" className="num">
                  Sisa
                </th>
                <th scope="col">Tindakan</th>
              </tr>
            </thead>
            <tbody>
              {liabilities.map((row, index) => (
                <tr key={`${row.liability}-${row.period_start}-${index}`}>
                  <td>{PAYROLL_LIABILITY_LABELS[row.liability]}</td>
                  <td data-label="Periode">{formatShortDate(row.period_start)}</td>
                  <td data-label="Proses">{row.run_number ?? "—"}</td>
                  <td className="num" data-label="Terutang">
                    {formatMoney(row.owed, currency)}
                  </td>
                  <td className="num" data-label="Dibayar">
                    {formatMoney(row.paid, currency)}
                  </td>
                  <td className="num" data-label="Sisa">
                    {formatMoney(row.outstanding, currency)}
                  </td>
                  <td data-label="Tindakan">
                    {row.liability === "pph21" && Number(row.outstanding) > 0 ? (
                      <Link href={pph21DepositHref(row.period_start, entity)}>Setor →</Link>
                    ) : (
                      "—"
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {reconciliation ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Rekonsiliasi Tahunan {year}</h2>
          </div>
          {reconciliation.length === 0 ? (
            <div className="list-empty">
              <p>Tidak ada karyawan pada tahun pajak ini.</p>
            </div>
          ) : (
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  <th scope="col">Karyawan</th>
                  <th scope="col" className="num">
                    Bulan Kerja
                  </th>
                  <th scope="col" className="num">
                    Penghasilan Bruto
                  </th>
                  <th scope="col" className="num">
                    Pajak Tahunan
                  </th>
                  <th scope="col" className="num">
                    Dipotong
                  </th>
                  <th scope="col" className="num">
                    Selisih
                  </th>
                  <th scope="col">Status</th>
                </tr>
              </thead>
              <tbody>
                {reconciliation.map((row) => {
                  const badge = annualReconciliationStatusBadge(row.status);
                  return (
                    <tr key={row.employee_id}>
                      <td>
                        {row.employee_code} — {row.employee_name}
                      </td>
                      <td className="num" data-label="Bulan Kerja">
                        {row.months_worked}
                      </td>
                      <td className="num" data-label="Penghasilan Bruto">
                        {formatMoney(row.gross_income, currency)}
                      </td>
                      <td className="num" data-label="Pajak Tahunan">
                        {money(row.annual_tax, currency)}
                      </td>
                      <td className="num" data-label="Dipotong">
                        {formatMoney(row.withheld, currency)}
                      </td>
                      <td className="num" data-label="Selisih">
                        {money(row.difference, currency)}
                      </td>
                      <td data-label="Status">
                        <span className={`status-badge status-badge-${badge.tone}`}>
                          {badge.text}
                        </span>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {certificates ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Bukti Potong Tahunan {year}</h2>
          </div>
          <p className="hint">
            Formulir 1721-A1 untuk tiap karyawan: rangkuman penghasilan dan PPh 21 setahun yang
            dipakai karyawan untuk mengisi SPT Tahunan mereka sendiri, paling lambat 31 Maret{" "}
            {year + 1}.
          </p>
          {certificates.length === 0 ? (
            <div className="list-empty">
              <p>Tidak ada karyawan pada tahun pajak ini.</p>
            </div>
          ) : (
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  <th scope="col">Karyawan</th>
                  <th scope="col" className="num">
                    Penghasilan Bruto
                  </th>
                  <th scope="col" className="num">
                    PPh 21 Setahun
                  </th>
                  <th scope="col" className="num">
                    Ditanggung Karyawan
                  </th>
                  <th scope="col">Status</th>
                  <th scope="col">Tindakan</th>
                </tr>
              </thead>
              <tbody>
                {certificates.map((row) => {
                  const badge = annualReconciliationStatusBadge(row.status);
                  return (
                    <tr key={row.employee_id}>
                      <td>
                        {row.employee_code} — {row.employee_name}
                      </td>
                      <td className="num" data-label="Penghasilan Bruto">
                        {formatMoney(row.gross_income, currency)}
                      </td>
                      <td className="num" data-label="PPh 21 Setahun">
                        {money(row.annual_tax, currency)}
                      </td>
                      <td className="num" data-label="Ditanggung Karyawan">
                        {formatMoney(row.borne_by_employee, currency)}
                      </td>
                      <td data-label="Status">
                        <span className={`status-badge status-badge-${badge.tone}`}>
                          {badge.text}
                        </span>
                      </td>
                      <td data-label="Tindakan">
                        <Link href={certificateHref(row.employee_id, year, entity)}>
                          Bukti potong →
                        </Link>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {taxLedger ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Buku Besar Pajak Karyawan {year}</h2>
          </div>
          {taxLedger.length === 0 ? (
            <div className="list-empty">
              <p>Tidak ada catatan pajak pada tahun pajak ini.</p>
            </div>
          ) : (
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  <th scope="col">Karyawan</th>
                  <th scope="col">Periode</th>
                  <th scope="col">Sumber</th>
                  <th scope="col">Proses</th>
                  <th scope="col" className="num">
                    Dasar Pajak
                  </th>
                  <th scope="col" className="num">
                    PPh 21
                  </th>
                  <th scope="col" className="num">
                    Tunjangan
                  </th>
                  <th scope="col" className="num">
                    Potongan Pensiun
                  </th>
                </tr>
              </thead>
              <tbody>
                {taxLedger.map((row, index) => (
                  <tr key={`${row.employee_id}-${row.tax_period}-${row.source}-${index}`}>
                    <td>
                      {row.employee_code} — {row.employee_name}
                    </td>
                    <td data-label="Periode">{payrollPeriodName(row.tax_period)}</td>
                    <td data-label="Sumber">{TAX_LEDGER_SOURCE_LABELS[row.source]}</td>
                    <td data-label="Proses">{row.run_number ?? "—"}</td>
                    <td className="num" data-label="Dasar Pajak">
                      {formatMoney(row.tax_base, currency)}
                    </td>
                    <td className="num" data-label="PPh 21">
                      {formatMoney(row.pph21, currency)}
                    </td>
                    <td className="num" data-label="Tunjangan">
                      {formatMoney(row.tax_allowance, currency)}
                    </td>
                    <td className="num" data-label="Potongan Pensiun">
                      {formatMoney(row.pension_deduction, currency)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {!canViewTax ? (
        <p className="hint">
          Rekonsiliasi tahunan, bukti potong dan buku besar pajak karyawan memerlukan izin{" "}
          <code>payroll.tax_view</code>.
        </p>
      ) : null}
    </div>
  );
}
