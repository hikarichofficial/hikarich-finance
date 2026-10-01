import { formatMoney } from "@/domain/money/format";
import {
  reconciliationListStatus,
  type ReconciliationListRow,
} from "@/domain/money/reconciliationList";
import { formatShortDate } from "./format";

/**
 * Reconciliation List (P13 unbuilt-screens backlog, Step 09 §13, decision 231): one row per financial
 * account, reading `reconciliation_status` -- the same RPC `AccountsListScreen`/`AccountDetailScreen`
 * already read for their own freshness badge, now given its own dedicated screen. No search/filter toolbar,
 * matching `PeriodsListScreen`'s own precedent for a status overview over a small, always-fully-shown row
 * count (one row per account, not a growing transactional list).
 *
 * Read-only for now: no "Start Session"/workspace UI. `create_reconciliation_session` and every action that
 * follows it (`add_statement_lines`, `match_statement_line`, `complete_reconciliation`, ...) are fully
 * wired and ready to call, but no RPC anywhere returns a `reconciliation_sessions` row's own fields (status,
 * period, statement balances) -- `reconciliation_status` is per-*account*, not per-*session*, and
 * `reconciliation_workspace` returns only its statement lines. A session workspace screen cannot honestly
 * show its own header or gate its own actions (open/reopened vs. reconciled) without that read, so it stays
 * on the catch-all pending a new RPC -- flagged in `docs/DECISIONS.md` (decision 231) as an OWNER-relevant
 * backend gap, the same class of finding as `/sales/products`/`/purchases/expenses`.
 */
export function ReconciliationListScreen({ rows }: { rows: readonly ReconciliationListRow[] }) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Rekonsiliasi Bank</h1>
          <p className="list-screen-summary">{rows.length} akun ditampilkan.</p>
        </div>
      </header>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada akun kas/bank untuk Entity ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Akun</th>
              <th scope="col">Direkonsiliasi Hingga</th>
              <th scope="col" className="num">
                Saldo Penutupan Terakhir
              </th>
              <th scope="col">Status</th>
              <th scope="col" className="num">
                Baris Belum Selesai
              </th>
              <th scope="col" className="num">
                Pergerakan Belum Cocok
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = reconciliationListStatus(row);
              return (
                <tr key={row.financial_account_id}>
                  <td data-label="Akun">
                    <strong>{row.name}</strong>
                  </td>
                  <td data-label="Direkonsiliasi Hingga">
                    {row.last_reconciled_until ? formatShortDate(row.last_reconciled_until) : "—"}
                  </td>
                  <td className="num" data-label="Saldo Penutupan Terakhir">
                    {row.last_statement_closing !== null
                      ? formatMoney(row.last_statement_closing, row.currency)
                      : "—"}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td className="num" data-label="Baris Belum Selesai">
                    {row.unresolved_lines}
                  </td>
                  <td className="num" data-label="Pergerakan Belum Cocok">
                    {row.outstanding_movements}
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
