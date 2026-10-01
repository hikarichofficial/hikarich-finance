import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  RECON_SESSION_STATUS_LABELS,
  RECON_SESSION_STATUS_TONES,
} from "@/domain/money/reconciliationSession";
import type { ReconciliationSessionRow } from "@/schemas/money";
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
 * Decision 251: each account links to its session in progress or starts a new one, and the session
 * history lists every session (read directly from `reconciliation_sessions`).
 */
export function ReconciliationListScreen({
  rows,
  sessions,
  entity,
  canReconcile,
}: {
  rows: readonly ReconciliationListRow[];
  sessions: readonly ReconciliationSessionRow[];
  entity: string | undefined;
  canReconcile: boolean;
}) {
  const qs = entity ? `entity=${encodeURIComponent(entity)}` : "";
  const sessionHref = (id: string) => `/money/reconciliation/${id}${qs ? `?${qs}` : ""}`;
  const newHref = (accountId: string) =>
    `/money/reconciliation/new?account=${accountId}${qs ? `&${qs}` : ""}`;
  const activeByAccount = new Map(
    sessions
      .filter((s) => s.status === "open" || s.status === "reopened")
      .map((s) => [s.financial_account_id, s.id]),
  );
  const nameByAccount = new Map(rows.map((r) => [r.financial_account_id, r.name]));
  const currencyByAccount = new Map(rows.map((r) => [r.financial_account_id, r.currency]));
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
              <th scope="col">Tindakan</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = reconciliationListStatus(row);
              const activeId = activeByAccount.get(row.financial_account_id);
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
                  <td data-label="Tindakan">
                    {activeId ? (
                      <Link href={sessionHref(activeId)}>Lanjutkan sesi</Link>
                    ) : canReconcile ? (
                      <Link href={newHref(row.financial_account_id)}>Mulai rekonsiliasi</Link>
                    ) : (
                      "—"
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Sesi</h2>
        </div>
        {sessions.length === 0 ? (
          <p>Belum ada sesi rekonsiliasi.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Akun</th>
                <th scope="col">Periode</th>
                <th scope="col" className="num">
                  Saldo Akhir Rekening Koran
                </th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {sessions.map((s) => (
                <tr key={s.id}>
                  <td>
                    <Link href={sessionHref(s.id)}>
                      {nameByAccount.get(s.financial_account_id) ?? "Akun"}
                    </Link>
                  </td>
                  <td data-label="Periode">
                    {formatShortDate(s.period_start)} – {formatShortDate(s.period_end)}
                  </td>
                  <td className="num" data-label="Saldo Akhir Rekening Koran">
                    {formatMoney(
                      s.statement_closing,
                      currencyByAccount.get(s.financial_account_id) ?? "IDR",
                    )}
                  </td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${RECON_SESSION_STATUS_TONES[s.status]}`}
                    >
                      {RECON_SESSION_STATUS_LABELS[s.status]}
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
