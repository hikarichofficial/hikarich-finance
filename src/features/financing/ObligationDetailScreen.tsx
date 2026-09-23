import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { OBLIGATION_KIND_LABELS } from "@/domain/financing/financing";
import {
  OBLIGATION_RECOGNITION_LABELS,
  OBLIGATION_SETTLEMENT_KIND_LABELS,
  OBLIGATION_SOURCE_LABELS,
  obligationKindTitle,
  obligationSettlementStatusBadge,
  obligationStatusBadge,
  type ObligationRecognition,
  type ObligationSettlementKind,
  type ObligationSettlementStatus,
} from "@/domain/financing/obligationList";
import type { ObligationDetail } from "@/schemas/financing";
import { formatShortDate } from "./format";

/**
 * Other Receivable / Other Payable Detail (P13 Part 3f, third increment, Step 09 §10, §16). Follows the same
 * narrower "Standard Record Detail Pattern subset" as Asset/Loan Detail (decisions 174/175): Header / Ringkasan
 * / Riwayat Pelunasan -- `obligation_detail`'s own settlements already ARE the obligation's detail, so no
 * separate placeholder section is added. The `financial_account_id`/`counter_account_id` fields are left
 * unlinked for the same reason as Loan Detail's own account ids (decision 175: no Chart of Accounts detail
 * route exists yet). An `asset_disposal`-sourced obligation's `source_id` points at the disposal event, which
 * has no detail route of its own (only the asset's own Detail page shows its disposal inline) -- also left
 * unlinked rather than guessed at, the same "only link what has somewhere to go" precedent (decision 172).
 */
export function ObligationDetailScreen({
  detail,
  currency,
  backHref,
  qs,
}: {
  detail: ObligationDetail;
  currency: string;
  backHref: string;
  qs: string;
}) {
  const statusBadge = obligationStatusBadge(detail.status, false);
  const title = obligationKindTitle(detail.kind);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar {title.toLowerCase()}</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{OBLIGATION_KIND_LABELS[detail.kind]}</p>
          <h1>{detail.number}</h1>
          <p className="record-detail-counterparty">{detail.counterparty}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
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
            <dt>Jatuh Tempo</dt>
            <dd>{detail.due_date ? formatShortDate(detail.due_date) : "—"}</dd>
          </div>
          <div>
            <dt>Pokok</dt>
            <dd>{formatMoney(detail.principal, currency)}</dd>
          </div>
          <div>
            <dt>Outstanding</dt>
            <dd>{formatMoney(detail.outstanding, currency)}</dd>
          </div>
          <div>
            <dt>Pengakuan</dt>
            <dd>{OBLIGATION_RECOGNITION_LABELS[detail.recognition as ObligationRecognition]}</dd>
          </div>
          <div>
            <dt>Sumber</dt>
            <dd>{OBLIGATION_SOURCE_LABELS[detail.source_type]}</dd>
          </div>
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
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Pelunasan</h2>
        </div>
        {detail.settlements.length === 0 ? (
          <p className="dashboard-empty">Belum ada pelunasan.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Nomor</th>
                <th scope="col">Tanggal</th>
                <th scope="col">Jenis</th>
                <th scope="col" className="num">
                  Pokok
                </th>
                <th scope="col">Status</th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {detail.settlements.map((settlement) => {
                const settlementBadge = obligationSettlementStatusBadge(
                  settlement.status as ObligationSettlementStatus,
                );
                return (
                  <tr key={settlement.id}>
                    <td>{settlement.number}</td>
                    <td>{formatShortDate(settlement.date)}</td>
                    <td>
                      {
                        OBLIGATION_SETTLEMENT_KIND_LABELS[
                          settlement.kind as ObligationSettlementKind
                        ]
                      }
                    </td>
                    <td className="num">{formatMoney(settlement.principal, currency)}</td>
                    <td>
                      <span className={`status-badge status-badge-${settlementBadge.tone}`}>
                        {settlementBadge.text}
                      </span>
                    </td>
                    <td>
                      <Link href={`/accounting/journal/${settlement.journal_id}${qs}`}>
                        Lihat →
                      </Link>
                      {settlement.reversal_journal_id ? (
                        <>
                          {" · "}
                          <Link href={`/accounting/journal/${settlement.reversal_journal_id}${qs}`}>
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
        )}
      </section>
    </div>
  );
}
