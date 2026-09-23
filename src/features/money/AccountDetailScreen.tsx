import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  accountListStatus,
  sourceTypeLabel,
  type AccountListRow,
} from "@/domain/money/accountsList";
import type { AccountActivityRow } from "@/schemas/money";
import { formatShortDate } from "./format";

/**
 * Account Detail (P13 Part 3c, Step 09 §10, §13: "Account detail resembles a clean bank ledger with filters,
 * running balance and source links"). Unlike Invoice/Bill Detail, an account is not itself a commercial
 * document with issue/void/correct actions, so this screen keeps only the two Standard Record Detail Pattern
 * areas that actually apply -- Header and a Summary that doubles as the ledger's own Activity -- rather than
 * padding out Accounting/Tax/Audit placeholders that would say nothing an account doesn't already show here.
 * Source links (Step 09 §13) are deferred: `account_activity`'s `source_type`/`source_id` point at records
 * (payments, refunds, vendor payments, transfers, tax payments...) that mostly don't have their own detail
 * screen yet in this codebase (only Invoices/Bills do, and neither is `money_movements`' own source_id), so
 * linking out today would mean guessing at routes rather than reading an actual established one.
 */
export function AccountDetailScreen({
  account,
  activity,
  backHref,
  range,
  entity,
}: {
  account: AccountListRow;
  activity: readonly AccountActivityRow[];
  backHref: string;
  range: { from: string; to: string };
  entity: string | undefined;
}) {
  const status = accountListStatus(account);
  const baseDiffers = account.currency !== "IDR";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar akun</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Akun Kas &amp; Bank · {account.kind}</p>
          <h1>{account.name}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">
            {formatMoney(account.movement_balance, account.currency)}
          </p>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Saldo Sistem</dt>
            <dd>{formatMoney(account.movement_balance, account.currency)}</dd>
          </div>
          {baseDiffers ? (
            <div>
              <dt>Saldo Sistem (IDR)</dt>
              <dd>{formatMoney(account.movement_base_balance, "IDR")}</dd>
            </div>
          ) : null}
          <div>
            <dt>Saldo Buku Besar</dt>
            <dd>{formatMoney(account.ledger_balance, account.currency)}</dd>
          </div>
          <div>
            <dt>Selisih</dt>
            <dd>{formatMoney(account.difference, account.currency)}</dd>
          </div>
          <div>
            <dt>Terakhir Direkonsiliasi</dt>
            <dd>
              {account.reconciliation?.last_reconciled_until
                ? formatShortDate(account.reconciliation.last_reconciled_until)
                : "Belum pernah"}
            </dd>
          </div>
          {account.reconciliation && account.reconciliation.unresolved_lines > 0 ? (
            <div>
              <dt>Baris Belum Selesai</dt>
              <dd>{account.reconciliation.unresolved_lines}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Dari
            <input type="date" name="from" defaultValue={range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={range.to} />
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
        {activity.length === 0 ? (
          <p className="dashboard-empty">Tidak ada aktivitas pada rentang tanggal ini.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Keterangan</th>
                <th scope="col">Jurnal</th>
                <th scope="col" className="num">
                  Masuk
                </th>
                <th scope="col" className="num">
                  Keluar
                </th>
                <th scope="col" className="num">
                  Saldo Berjalan
                </th>
              </tr>
            </thead>
            <tbody>
              {activity.map((movement) => (
                <tr key={movement.movement_id}>
                  <td>{formatShortDate(movement.movement_date)}</td>
                  <td>
                    {sourceTypeLabel(movement.source_type)}
                    {movement.description ? ` — ${movement.description}` : ""}
                    {movement.reverses_movement_id ? " (pembalik)" : ""}
                  </td>
                  <td>{movement.journal_number ?? "—"}</td>
                  <td className="num">
                    {movement.direction === "in"
                      ? formatMoney(movement.amount, movement.currency)
                      : ""}
                  </td>
                  <td className="num">
                    {movement.direction === "out"
                      ? formatMoney(movement.amount, movement.currency)
                      : ""}
                  </td>
                  <td className="num">
                    {formatMoney(movement.running_balance, movement.currency)}
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
