import { formatMoney } from "@/domain/money/format";
import { PAYROLL_LIABILITY_LABELS, payrollPeriodName } from "@/domain/payroll/payroll";
import {
  TAX_LEDGER_SOURCE_LABELS,
  annualReconciliationStatusBadge,
} from "@/domain/payroll/taxLiabilities";
import type { AnnualReconciliationRow, PayrollLiabilityRow, TaxLedgerRow } from "@/schemas/payroll";
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
 */
export function PayrollTaxScreen({
  liabilities,
  reconciliation,
  taxLedger,
  asOf,
  year,
  currency,
  entity,
  canViewTax,
}: {
  liabilities: readonly PayrollLiabilityRow[];
  reconciliation: readonly AnnualReconciliationRow[] | null;
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
          <h1>Pajak & Kewajiban Penggajian</h1>
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
          <table className="record-table">
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
              </tr>
            </thead>
            <tbody>
              {liabilities.map((row, index) => (
                <tr key={`${row.liability}-${row.period_start}-${index}`}>
                  <td>{PAYROLL_LIABILITY_LABELS[row.liability]}</td>
                  <td>{formatShortDate(row.period_start)}</td>
                  <td>{row.run_number ?? "—"}</td>
                  <td className="num">{formatMoney(row.owed, currency)}</td>
                  <td className="num">{formatMoney(row.paid, currency)}</td>
                  <td className="num">{formatMoney(row.outstanding, currency)}</td>
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
            <table className="record-table">
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
                      <td className="num">{row.months_worked}</td>
                      <td className="num">{formatMoney(row.gross_income, currency)}</td>
                      <td className="num">{money(row.annual_tax, currency)}</td>
                      <td className="num">{formatMoney(row.withheld, currency)}</td>
                      <td className="num">{money(row.difference, currency)}</td>
                      <td>
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
            <table className="record-table">
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
                    <td>{payrollPeriodName(row.tax_period)}</td>
                    <td>{TAX_LEDGER_SOURCE_LABELS[row.source]}</td>
                    <td>{row.run_number ?? "—"}</td>
                    <td className="num">{formatMoney(row.tax_base, currency)}</td>
                    <td className="num">{formatMoney(row.pph21, currency)}</td>
                    <td className="num">{formatMoney(row.tax_allowance, currency)}</td>
                    <td className="num">{formatMoney(row.pension_deduction, currency)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </section>
      ) : null}

      {!canViewTax ? (
        <p className="hint">
          Rekonsiliasi tahunan dan buku besar pajak karyawan memerlukan izin{" "}
          <code>payroll.tax_view</code>.
        </p>
      ) : null}
    </div>
  );
}
