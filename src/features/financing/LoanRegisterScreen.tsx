import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { LoanDirection, LoanStatus } from "@/domain/financing/financing";
import {
  LOAN_DIRECTION_FILTER_OPTIONS,
  LOAN_STATUS_FILTER_OPTIONS,
  loanOverdueBadge,
  loanStatusBadge,
  type LoanDirectionFilterOption,
  type LoanStatusFilterOption,
} from "@/domain/financing/loanList";
import { LOAN_DIRECTION_LABELS } from "@/domain/financing/financing";
import type { LoanRow } from "@/schemas/financing";
import { formatShortDate } from "./format";

/**
 * Loan Register (P13 Part 3f, second increment, Step 09 §9, §16: "Loan dashboard shows principal outstanding,
 * next due, interest/fee split and schedule"). Follows the same Standard List Screen Pattern as the Asset
 * Register (decision 174): direction and status are sent straight to `loan_list`'s own `p_direction`/`p_status`
 * arguments (server-side filtering), and only the free-text search is client-side. No Create button here either
 * for the same reason as the Asset Register's own choice not to duplicate the create workflow (loan creation is
 * a dedicated command flow, out of scope for this List/Detail increment).
 */
export function LoanRegisterScreen({
  rows,
  direction,
  status,
  query,
  currency,
  entity,
}: {
  rows: readonly LoanRow[];
  direction: LoanDirection | null;
  status: LoanStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Daftar Pinjaman</h1>
          <p className="list-screen-summary">{rows.length} pinjaman ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Arah
            <select name="direction" defaultValue={direction ?? ""}>
              {LOAN_DIRECTION_FILTER_OPTIONS.map((option: LoanDirectionFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {LOAN_STATUS_FILTER_OPTIONS.map((option: LoanStatusFilterOption) => (
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
            placeholder="Cari nomor pinjaman atau pihak…"
            aria-label="Cari pinjaman"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada pinjaman pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Arah</th>
              <th scope="col">Pihak</th>
              <th scope="col" className="num">
                Pokok
              </th>
              <th scope="col" className="num">
                Outstanding
              </th>
              <th scope="col">Jatuh Tempo Berikutnya</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const statusBadge = loanStatusBadge(row.status);
              const overdueBadge = loanOverdueBadge(row.overdue);
              const href = entity
                ? `/assets/loans/${row.loan_id}?entity=${encodeURIComponent(entity)}`
                : `/assets/loans/${row.loan_id}`;
              return (
                <tr key={row.loan_id}>
                  <td>
                    <Link href={href}>{row.loan_number}</Link>
                  </td>
                  <td>{LOAN_DIRECTION_LABELS[row.direction]}</td>
                  <td>{row.counterparty_name}</td>
                  <td className="num">{formatMoney(row.principal, currency)}</td>
                  <td className="num">{formatMoney(row.outstanding, currency)}</td>
                  <td>
                    {row.next_due_date ? (
                      <>
                        {formatShortDate(row.next_due_date)}
                        {row.next_due_amount ? (
                          <span className="hint">
                            {" "}
                            · {formatMoney(row.next_due_amount, currency)}
                          </span>
                        ) : null}
                      </>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td>
                    <span className={`status-badge status-badge-${statusBadge.tone}`}>
                      {statusBadge.text}
                    </span>
                    {overdueBadge ? (
                      <span className={`status-badge status-badge-${overdueBadge.tone}`}>
                        {overdueBadge.text}
                      </span>
                    ) : null}
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
