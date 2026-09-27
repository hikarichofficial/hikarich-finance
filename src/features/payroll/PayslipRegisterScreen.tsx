import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { payrollPeriodName, type PayslipStatus } from "@/domain/payroll/payroll";
import {
  PAYSLIP_STATUS_FILTER_OPTIONS,
  payslipStatusBadge,
  type PayslipStatusFilterOption,
} from "@/domain/payroll/payslipList";
import type { PayslipRow } from "@/schemas/payroll";
import { formatShortDate } from "./format";

/**
 * Payslip Register (P13 Part 3g, third increment, Step 09 §17). `payroll_payslip_list` takes no status
 * argument (only `p_run`/`p_employee`/`p_limit`), so status stays a client-side filter, the same shape
 * Employee Register's own status filter takes; `?q=` (payslip number, employee code/name, period) is client-
 * side too. No filter form for run/employee here -- both are optional RPC arguments meant for deep-linking
 * (e.g. a future "Payslips" link from Payroll Run Detail or Employee Detail), not something this screen's own
 * toolbar exposes yet. No Create button: a payslip is issued as part of the payroll run wizard, not created
 * directly, so there is nothing to create here at all -- unlike every other Register screen's own deferred
 * create form, this one is not a future increment, it simply does not apply to this screen.
 */
export function PayslipRegisterScreen({
  rows,
  status,
  query,
  currency,
  entity,
}: {
  rows: readonly PayslipRow[];
  status: PayslipStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Slip Gaji</h1>
          <p className="list-screen-summary">{rows.length} slip gaji ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {PAYSLIP_STATUS_FILTER_OPTIONS.map((option: PayslipStatusFilterOption) => (
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
            placeholder="Cari nomor slip, karyawan atau periode…"
            aria-label="Cari slip gaji"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada slip gaji pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Karyawan</th>
              <th scope="col">Periode</th>
              <th scope="col">Diterbitkan</th>
              <th scope="col" className="num">
                Gaji Bersih
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = payslipStatusBadge(row.status);
              const href = entity
                ? `/payroll/payslips/${row.payslip_id}?entity=${encodeURIComponent(entity)}`
                : `/payroll/payslips/${row.payslip_id}`;
              return (
                <tr key={row.payslip_id}>
                  <td>
                    <Link href={href}>{row.payslip_number}</Link>
                  </td>
                  <td>
                    {row.employee_code} — {row.employee_name}
                  </td>
                  <td>{payrollPeriodName(`${row.period}-01`)}</td>
                  <td>{formatShortDate(row.issued_at.slice(0, 10))}</td>
                  <td className="num">{formatMoney(row.net_pay, currency)}</td>
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
