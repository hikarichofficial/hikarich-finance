import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  transferActivityTimeline,
  transferListStatus,
  type TransferListRow,
} from "@/domain/money/transferList";
import { TransferActions, type TransferActionPermissions } from "./TransferActions";
import { formatShortDate } from "./format";

/**
 * Transfer Detail (P13 Part 3c, Step 09 §10, §13): Header/Summary/Activity, the same Standard Record Detail
 * Pattern subset Account Detail uses (decision 169) -- a transfer has a lifecycle (draft/confirmed/reversed/
 * cancelled) but, unlike Invoices/Bills, no tax determination or per-record documents of its own, so
 * Accounting/Tax/Documents/Audit placeholders would say nothing new; the journal it posts is already visible
 * from each side's own Account Detail ledger (`sourceTypeLabel`'s "Transfer Antar Akun" row).
 */
export function TransferDetailScreen({
  transfer,
  permissions,
  backHref,
}: {
  transfer: TransferListRow;
  permissions: TransferActionPermissions;
  backHref: string;
}) {
  const status = transferListStatus(transfer);
  const timeline = transferActivityTimeline(transfer);
  const sameCurrency = transfer.from_account_currency === transfer.to_account_currency;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar transfer</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Transfer Antar Akun</p>
          <h1>{transfer.transfer_number ?? "Draf"}</h1>
          <p className="record-detail-counterparty">
            {transfer.from_account_name} → {transfer.to_account_name}
          </p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">
            {formatMoney(transfer.amount_out, transfer.from_account_currency)}
          </p>
          <p className="record-detail-dates">{formatShortDate(transfer.transfer_date)}</p>
        </div>
      </header>

      <TransferActions
        transferId={transfer.id}
        status={transfer.status}
        permissions={permissions}
      />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Dari Akun</dt>
            <dd>{transfer.from_account_name}</dd>
          </div>
          <div>
            <dt>Ke Akun</dt>
            <dd>{transfer.to_account_name}</dd>
          </div>
          <div>
            <dt>Jumlah Dikirim</dt>
            <dd>{formatMoney(transfer.amount_out, transfer.from_account_currency)}</dd>
          </div>
          <div>
            <dt>Jumlah Diterima</dt>
            <dd>{formatMoney(transfer.amount_in, transfer.to_account_currency)}</dd>
          </div>
          {Number(transfer.fee_amount) > 0 ? (
            <div>
              <dt>Biaya Bank</dt>
              <dd>{formatMoney(transfer.fee_amount, transfer.from_account_currency)}</dd>
            </div>
          ) : null}
          {!sameCurrency ? (
            <div>
              <dt>Selisih Kurs</dt>
              <dd>{formatMoney(transfer.fx_difference, "IDR")}</dd>
            </div>
          ) : null}
          {transfer.description ? (
            <div>
              <dt>Deskripsi</dt>
              <dd>{transfer.description}</dd>
            </div>
          ) : null}
          {transfer.reference ? (
            <div>
              <dt>Referensi</dt>
              <dd>{transfer.reference}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <ul className="record-activity-list">
          {timeline.map((entry, index) => (
            <li key={`${entry.label}-${index}`} className="record-activity-item">
              <span className={`status-badge status-badge-${entry.tone}`}>{entry.label}</span>
              {entry.date ? (
                <span className="record-activity-date">
                  {formatShortDate(entry.date.slice(0, 10))}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
