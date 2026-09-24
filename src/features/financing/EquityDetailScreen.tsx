import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { EQUITY_CLASS_LABELS, EQUITY_KIND_LABELS } from "@/domain/financing/financing";
import {
  equityPaymentStatusBadge,
  equityRetainedEarningsBadge,
  equityStatusBadge,
  type EquityPaymentStatus,
} from "@/domain/financing/equityList";
import type { EquityDetail } from "@/schemas/financing";
import { formatShortDate } from "./format";

/**
 * Capital & Equity Detail (P13 Part 3f, fourth increment, Step 09 §10, §16). Follows the same narrower "Standard
 * Record Detail Pattern subset" as Asset/Loan/Obligation Detail (decisions 174/175/176): Header / Ringkasan,
 * plus a Riwayat Pembayaran section only when the event carries dividend payments -- `equity_detail`'s own
 * `payments` array is empty for every kind except `dividend` (a declared-but-unpaid dividend has `outstanding`
 * but no payments yet). `financial_account_id` is left unlinked, the same "no Chart of Accounts detail route
 * yet" reason Loan/Obligation Detail's own account ids were left unlinked.
 */
export function EquityDetailScreen({
  detail,
  currency,
  backHref,
  qs,
}: {
  detail: EquityDetail;
  currency: string;
  backHref: string;
  qs: string;
}) {
  const statusBadge = equityStatusBadge(detail.status);
  const retainedBadge = equityRetainedEarningsBadge(detail.exceeds_retained_earnings);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke Modal & Ekuitas</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{EQUITY_KIND_LABELS[detail.kind]}</p>
          <h1>{detail.number}</h1>
          <p className="record-detail-counterparty">{detail.counterparty}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
          {retainedBadge ? (
            <span className={`status-badge status-badge-${retainedBadge.tone}`}>
              {retainedBadge.text}
            </span>
          ) : null}
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Tujuan</dt>
            <dd>{detail.purpose}</dd>
          </div>
          <div>
            <dt>Tanggal</dt>
            <dd>{formatShortDate(detail.date)}</dd>
          </div>
          <div>
            <dt>Jumlah</dt>
            <dd>{formatMoney(detail.amount, currency)}</dd>
          </div>
          {detail.outstanding !== null ? (
            <div>
              <dt>Belum Dibayar</dt>
              <dd>{formatMoney(detail.outstanding, currency)}</dd>
            </div>
          ) : null}
          {detail.equity_class ? (
            <div>
              <dt>Kelas Ekuitas</dt>
              <dd>{EQUITY_CLASS_LABELS[detail.equity_class]}</dd>
            </div>
          ) : null}
          {detail.retained_available !== null ? (
            <div>
              <dt>Laba Ditahan Tersedia</dt>
              <dd>{formatMoney(detail.retained_available, currency)}</dd>
            </div>
          ) : null}
          {detail.resolution_reference ? (
            <div>
              <dt>Referensi Keputusan RUPS</dt>
              <dd>{detail.resolution_reference}</dd>
            </div>
          ) : null}
          {detail.relationship_basis ? (
            <div>
              <dt>Dasar Hubungan</dt>
              <dd>{detail.relationship_basis}</dd>
            </div>
          ) : null}
          {detail.journal_id ? (
            <div>
              <dt>Jurnal</dt>
              <dd>
                <Link href={`/accounting/journal/${detail.journal_id}${qs}`}>Lihat →</Link>
              </dd>
            </div>
          ) : null}
          {detail.reversal_journal_id ? (
            <div>
              <dt>Jurnal Pembalik</dt>
              <dd>
                <Link href={`/accounting/journal/${detail.reversal_journal_id}${qs}`}>Lihat →</Link>
              </dd>
            </div>
          ) : null}
          {detail.reverse_reason ? (
            <div>
              <dt>Alasan Dibalik</dt>
              <dd>{detail.reverse_reason}</dd>
            </div>
          ) : null}
          {detail.cancel_reason ? (
            <div>
              <dt>Alasan Dibatalkan</dt>
              <dd>{detail.cancel_reason}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      {detail.payments.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Riwayat Pembayaran</h2>
          </div>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Nomor</th>
                <th scope="col">Tanggal</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Status</th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {detail.payments.map((payment) => {
                const paymentBadge = equityPaymentStatusBadge(
                  payment.status as EquityPaymentStatus,
                );
                return (
                  <tr key={payment.id}>
                    <td>{payment.number}</td>
                    <td>{formatShortDate(payment.date)}</td>
                    <td className="num">{formatMoney(payment.amount, currency)}</td>
                    <td>
                      <span className={`status-badge status-badge-${paymentBadge.tone}`}>
                        {paymentBadge.text}
                      </span>
                    </td>
                    <td>
                      <Link href={`/accounting/journal/${payment.journal_id}${qs}`}>Lihat →</Link>
                      {payment.reversal_journal_id ? (
                        <>
                          {" · "}
                          <Link href={`/accounting/journal/${payment.reversal_journal_id}${qs}`}>
                            Pembalik →
                          </Link>
                        </>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      ) : null}
    </div>
  );
}
