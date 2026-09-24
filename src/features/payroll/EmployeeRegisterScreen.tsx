import Link from "next/link";
import {
  EMPLOYMENT_TYPE_LABELS,
  type EmployeeStatus,
  type EmploymentType,
} from "@/domain/payroll/payroll";
import {
  EMPLOYEE_STATUS_FILTER_OPTIONS,
  EMPLOYMENT_TYPE_FILTER_OPTIONS,
  employeeStatusBadge,
  type EmployeeStatusFilterOption,
  type EmploymentTypeFilterOption,
} from "@/domain/payroll/employeeList";
import type { EmployeeRow } from "@/schemas/payroll";
import { formatShortDate } from "./format";

/**
 * Employee Register (P13 Part 3g, first increment, Step 09 §9-§10, §17: "Payroll is isolated as a sensitive
 * module. Employee list shows only appropriate operational fields; compensation is permission-gated."). No
 * amount ever reaches this screen: `employee_list` itself never returns a compensation figure (enforced by
 * the database, not by this screen), so there is nothing here to gate. `status` and employment `type` are
 * both client-side filters -- `employee_list`'s own argument is `p_include_ended` (a boolean), not a status
 * enum, so both refine what the server already included rather than triggering a second round-trip; `?q=` is
 * a client-side code/name/position/department search. No Create button: employee creation is a dedicated
 * command flow, out of scope for this List/Detail increment, the same boundary every other Part 3 Register
 * screen's first increment drew.
 */
export function EmployeeRegisterScreen({
  rows,
  status,
  employmentType,
  query,
  entity,
}: {
  rows: readonly EmployeeRow[];
  status: EmployeeStatus | null;
  employmentType: EmploymentType | null;
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Karyawan</h1>
          <p className="list-screen-summary">{rows.length} karyawan ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {EMPLOYEE_STATUS_FILTER_OPTIONS.map((option: EmployeeStatusFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Jenis
            <select name="type" defaultValue={employmentType ?? ""}>
              {EMPLOYMENT_TYPE_FILTER_OPTIONS.map((option: EmploymentTypeFilterOption) => (
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
            placeholder="Cari kode, nama, jabatan atau departemen…"
            aria-label="Cari karyawan"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada karyawan pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Kode</th>
              <th scope="col">Nama</th>
              <th scope="col">Jabatan</th>
              <th scope="col">Departemen</th>
              <th scope="col">Jenis</th>
              <th scope="col">Tanggal Masuk</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = employeeStatusBadge(row.status);
              const href = entity
                ? `/payroll/employees/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/payroll/employees/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.employee_code}</Link>
                  </td>
                  <td>{row.full_name}</td>
                  <td>{row.position_title}</td>
                  <td>{row.department ?? "—"}</td>
                  <td>{EMPLOYMENT_TYPE_LABELS[row.employment_type]}</td>
                  <td>{formatShortDate(row.join_date)}</td>
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
