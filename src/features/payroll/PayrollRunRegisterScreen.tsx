import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { payrollPeriodName, type PayrollStatus } from "@/domain/payroll/payroll";
import {
  PAYROLL_RUN_STATUS_FILTER_OPTIONS,
  payrollRunStatusBadge,
  type PayrollRunStatusFilterOption,
} from "@/domain/payroll/runList";
import type { PayrollRunRow } from "@/schemas/payroll";
import { formatShortDate } from "./format";

/**
 * Payroll Run Register (P13 Part 3g, second increment, Step 09 §17's own period -> employees -> calculation ->
 * review -> approval -> post/pay -> close wizard). This increment ships the read surface only: `?status=` is
 * sent straight to `payroll_run_list`'s own `p_status` argument (server-side filtering, matching the Loan
 * Register's own direction/status split, decision 175); `?q=` is a client-side run-number/period search. No
 * Create button: starting a new run (`createPayrollRun`) is a dedicated command flow, out of scope for this
 * List/Detail increment, the same boundary every other Part 3 Register screen's first increment drew.
 * `tax_allowance_total`/`pph21_total` are null for a viewer without `payroll.tax_view` (the RPC's own doing,
 * not this screen's) -- shown as "—" rather than 0, so a masked figure is never mistaken for an actual zero.
 */
export function PayrollRunRegisterScreen({
  rows,
  status,
  query,
  currency,
  entity,
}: {
  rows: readonly PayrollRunRow[];
  status: PayrollStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Proses Penggajian</h1>
          <p className="list-screen-summary">{rows.length} proses ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {PAYROLL_RUN_STATUS_FILTER_OPTIONS.map((option: PayrollRunStatusFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor proses atau periode…"
            aria-label="Cari proses penggajian"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada proses penggajian pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Periode</th>
              <th scope="col">Tanggal Bayar</th>
              <th scope="col" className="num">
                Karyawan
              </th>
              <th scope="col" className="num">
                Gaji Bersih
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = payrollRunStatusBadge(row.status);
              const href = entity
                ? `/payroll/runs/${row.run_id}?entity=${encodeURIComponent(entity)}`
                : `/payroll/runs/${row.run_id}`;
              return (
                <tr key={row.run_id}>
                  <td>
                    <Link href={href}>{row.run_number}</Link>
                  </td>
                  <td>{payrollPeriodName(row.period_start)}</td>
                  <td>{formatShortDate(row.pay_date)}</td>
                  <td className="num">{row.employee_count}</td>
                  <td className="num">{formatMoney(row.net_pay_total, currency)}</td>
                  <td>
                    <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
