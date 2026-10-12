import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { TAX_TYPE_LABELS, resolveFilingTaxType, taxPeriodLabel } from "@/domain/tax/tax";
import type { TaxEvidenceRow, TaxPaymentRow } from "@/schemas/tax";
import { BackLink } from "@/features/shell/BackLink";
import { PageHelp } from "@/features/shared/PageHelp";
import { EvidenceList } from "./TaxEvidenceList";
import { ReversePaymentForm, TaxEvidenceUploadForm } from "./TaxPaymentForms";
import { formatShortDate } from "./format";

/**
 * The page of one tax payment (decision 414), laid out like the invoice and Pembayaran Diterima pages: back
 * link, title with status and amount, summary, journals and attachments. It replaces the expandable block that
 * used to open under Riwayat Pembayaran. The proofs (receipt of payment, NTPN, billing slip) open in the
 * preview, and a proof can be uploaded here at any time, also long after the payment was recorded. A confirmed
 * payment is reversed from here with a counter-journal (never deleted).
 */
export function TaxPaymentDetailScreen({
  payment,
  currency,
  entityId,
  entity,
  accountName,
  evidence,
  backHref,
}: {
  payment: TaxPaymentRow;
  currency: string;
  entityId: string;
  entity: string | undefined;
  accountName: string | null;
  evidence: readonly TaxEvidenceRow[];
  backHref: string;
}) {
  const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const confirmed = payment.status === "confirmed";
  const taxType = resolveFilingTaxType(payment.tax_type);
  const period = payment.tax_period.slice(0, 7);
  const hasOffset = Number(payment.asset_applied) !== 0;
  const hasPenalty = Number(payment.penalty_amount) !== 0;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke pelaporan &amp; bukti</BackLink>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pembayaran Pajak</p>
          <h1>{payment.payment_number}</h1>
          <PageHelp />
          <p className="record-detail-counterparty">
            {TAX_TYPE_LABELS[payment.tax_type]} &middot; Masa Pajak{" "}
            {taxPeriodLabel(payment.tax_period)}
          </p>
        </div>
        <div className="record-detail-header-end">
          <span
            className={`status-badge ${confirmed ? "status-badge-success" : "status-badge-neutral"}`}
          >
            {confirmed ? "Terkonfirmasi" : "Dibalik"}
          </span>
          <p className="record-detail-amount">{formatMoney(payment.payable_applied, currency)}</p>
          <p className="record-detail-dates">{formatShortDate(payment.payment_date)}</p>
        </div>
      </header>

      {confirmed ? (
        <div className="invoice-action-buttons">
          <ReversePaymentForm
            paymentId={payment.payment_id}
            taxType={taxType}
            period={period}
            entityId={entityId}
            entity={entity}
          />
        </div>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Tanggal Bayar</dt>
            <dd>{formatShortDate(payment.payment_date)}</dd>
          </div>
          <div>
            <dt>Jenis Pajak</dt>
            <dd>{TAX_TYPE_LABELS[payment.tax_type]}</dd>
          </div>
          <div>
            <dt>Masa Pajak</dt>
            <dd>{taxPeriodLabel(payment.tax_period)}</dd>
          </div>
          <div>
            <dt>Pajak Dibayar</dt>
            <dd>{formatMoney(payment.payable_applied, currency)}</dd>
          </div>
          {hasOffset ? (
            <div>
              <dt>Kompensasi</dt>
              <dd>{formatMoney(payment.asset_applied, currency)}</dd>
            </div>
          ) : null}
          {hasPenalty ? (
            <div>
              <dt>Denda</dt>
              <dd>{formatMoney(payment.penalty_amount, currency)}</dd>
            </div>
          ) : null}
          <div>
            <dt>Uang Keluar</dt>
            <dd>{formatMoney(payment.cash_amount, currency)}</dd>
          </div>
          <div>
            <dt>Dibayar dari Akun</dt>
            <dd>{accountName ?? "Dikompensasi penuh (tanpa akun)"}</dd>
          </div>
          <div>
            <dt>NTPN dan Kode Billing</dt>
            <dd>{payment.reference ?? "Belum diisi"}</dd>
          </div>
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Jurnal</h2>
        </div>
        {payment.journal_id || payment.reversal_journal_id ? (
          <dl className="record-summary-grid">
            {payment.journal_id ? (
              <div>
                <dt>Jurnal Pembayaran</dt>
                <dd>
                  <Link href={`/accounting/journal/${payment.journal_id}${suffix}`}>
                    Lihat jurnal
                  </Link>
                </dd>
              </div>
            ) : null}
            {payment.reversal_journal_id ? (
              <div>
                <dt>Jurnal Pembalikan</dt>
                <dd>
                  <Link href={`/accounting/journal/${payment.reversal_journal_id}${suffix}`}>
                    Lihat jurnal pembalikan
                  </Link>
                </dd>
              </div>
            ) : null}
          </dl>
        ) : (
          <p className="dashboard-empty">Pembayaran ini belum punya jurnal.</p>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Lampiran</h2>
        </div>
        <EvidenceList title={null} rows={evidence} />
        {confirmed ? (
          <TaxEvidenceUploadForm
            targets={[
              {
                type: "tax_payment",
                id: payment.payment_id,
                label: `Pembayaran ${payment.payment_number}`,
              },
            ]}
            taxType={taxType}
            period={period}
            entity={entity}
            backToPayment={payment.payment_id}
          />
        ) : (
          <p className="hint">Pembayaran yang sudah dibalik tidak dapat diberi lampiran baru.</p>
        )}
      </section>
    </div>
  );
}
