import { translateReason } from "@/domain/authz/translateReason";
import { formatMoney } from "@/domain/money/format";
import {
  DETERMINATION_STATUS_LABELS,
  DETERMINATION_STATUS_TONE,
  DIFFERENCE_LABELS,
  taxPeriodLabel,
  type DeterminationStatus,
} from "@/domain/tax/tax";
import type { FinalPreview, TaxPeriodPosition } from "@/schemas/tax";
import { formatShortDate } from "./format";
import { TaxEstimateCard } from "./TaxEstimateCard";

/**
 * PPh Final UMKM (P13 unbuilt-screens backlog, "PPh Final / Income Tax" nav item, Step 05 §9, decision 234):
 * a flat rate on turnover recognised once a month. A period picker (a native `<input type="month">`) selects
 * the month; "Pratinjau" shows `tax_final_preview`'s live, unrecorded evaluation of that month, and "Posisi
 * Tercatat" shows what `tax_period_position` says is actually on the books. The tax of an ended month is
 * computed and recorded by the scheduled job on the first day after it ends (decision 346), so there is no
 * compute button; the running month shows the live estimate.
 */
export function TaxFinalScreen({
  period,
  preview,
  position,
  currency,
  entity,
  estimate,
  estimatePeriod,
}: {
  estimate: FinalPreview;
  estimatePeriod: string;
  period: string;
  preview: FinalPreview;
  position: TaxPeriodPosition;
  currency: string;
  entity: string | undefined;
}) {
  const previewStatus = preview.status as DeterminationStatus;
  const previewTone = DETERMINATION_STATUS_TONE[previewStatus];
  const canCompute = preview.status === "auto_determined";
  const periodEnded = period.slice(0, 7) < estimatePeriod.slice(0, 7);
  const recorded = Number(position.accrued_payable);

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>PPh Final UMKM</h1>
          <p className="record-detail-counterparty">Masa Pajak {taxPeriodLabel(period)}</p>
        </div>
      </header>

      <TaxEstimateCard
        estimate={estimate}
        period={estimatePeriod}
        currency={currency}
        entity={entity}
        linkToFinal={false}
      />

      <form method="get" className="list-search-form">
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}
        <label>
          Masa Pajak
          <input type="month" name="period" defaultValue={period.slice(0, 7)} />
        </label>
        <button type="submit" className="btn-secondary">
          Terapkan
        </button>
      </form>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pratinjau</h2>
        </div>
        <p className="hint">
          Perhitungan langsung, belum tercatat -- apa yang akan terjadi jika dihitung sekarang.
        </p>
        <dl className="record-summary-grid">
          <div>
            <dt>Status</dt>
            <dd>
              <span className={`status-badge status-badge-${previewTone}`}>
                {DETERMINATION_STATUS_LABELS[previewStatus]}
              </span>
            </dd>
          </div>
          <div>
            <dt>Pajak</dt>
            <dd>{formatMoney(preview.tax, currency)}</dd>
          </div>
          {preview.base !== undefined ? (
            <div>
              <dt>Dasar Pengenaan</dt>
              <dd>{formatMoney(preview.base, currency)}</dd>
            </div>
          ) : null}
        </dl>
        {preview.reasons.length > 0 ? (
          <ul className="dashboard-list">
            {preview.reasons.map((reason, i) => (
              <li key={i} className="dashboard-list-item-detail">
                {translateReason(reason) ?? reason}
              </li>
            ))}
          </ul>
        ) : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Posisi Tercatat</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Terutang (Diakui)</dt>
            <dd>{formatMoney(position.accrued_payable, currency)}</dd>
          </div>
          <div>
            <dt>Sudah Dibayar</dt>
            <dd>{formatMoney(position.paid_payable, currency)}</dd>
          </div>
          <div>
            <dt>Sisa Kekurangan</dt>
            <dd>{formatMoney(position.outstanding_payable, currency)}</dd>
          </div>
          <div>
            <dt>Pelaporan</dt>
            <dd>
              {position.filed_reference
                ? `Dilaporkan (${position.filed_reference})`
                : "Belum dilaporkan"}
            </dd>
          </div>
          <div>
            <dt>Bukti Terlampir</dt>
            <dd>{position.evidence_count}</dd>
          </div>
          <div>
            <dt>Per Tanggal</dt>
            <dd>{formatShortDate(position.as_of)}</dd>
          </div>
        </dl>
        {position.differences.length > 0 ? (
          <ul className="dashboard-list">
            {position.differences.map((diff, i) => (
              <li key={i} className="dashboard-list-item">
                <p className="dashboard-list-item-title">{DIFFERENCE_LABELS[diff.code]}</p>
                <p className="dashboard-list-item-detail">{diff.text}</p>
                {diff.amount !== null ? (
                  <span className="dashboard-list-item-value">
                    {formatMoney(diff.amount, currency)}
                  </span>
                ) : null}
              </li>
            ))}
          </ul>
        ) : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Dihitung Otomatis</h2>
        </div>
        <p className="hint">
          Pajak final bulan yang sudah berakhir dihitung dan dicatat sendiri oleh sistem mulai
          tanggal 1 bulan berikutnya; tidak perlu menekan tombol. Selama bulan berjalan, angka di
          atas adalah perkiraan yang ikut berubah setiap ada pendapatan baru.
        </p>
        {!canCompute ? (
          <p className="hint">
            Masa ini belum bisa dihitung ({DETERMINATION_STATUS_LABELS[previewStatus]}).
          </p>
        ) : periodEnded && recorded === 0 && Number(preview.tax) > 0 ? (
          <p className="hint">
            Belum tercatat. Sistem akan mencatatnya pada pengecekan harian berikutnya.
          </p>
        ) : null}
      </section>
    </div>
  );
}
