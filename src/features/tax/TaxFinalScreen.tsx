"use client";

import { useActionState } from "react";
import { formatMoney } from "@/domain/money/format";
import {
  DETERMINATION_STATUS_LABELS,
  DETERMINATION_STATUS_TONE,
  DIFFERENCE_LABELS,
  taxPeriodLabel,
  type DeterminationStatus,
} from "@/domain/tax/tax";
import type { FinalPreview, TaxPeriodPosition } from "@/schemas/tax";
import { computeFinalTaxAction } from "./taxFinalActions";
import { idleComputeFinalTaxFormState } from "./taxFinalActionsState";
import { formatShortDate } from "./format";

/**
 * PPh Final UMKM (P13 unbuilt-screens backlog, "PPh Final / Income Tax" nav item, Step 05 §9, decision 234):
 * the one tax type with its own compute step (`tax_final_compute`) rather than a plain accrual, since the
 * UMKM final-tax regime is a flat rate on turnover recognised only once a month, not line by line. A period
 * picker (a native `<input type="month">`, no client script needed for its own GET submission) selects the
 * month; "Pratinjau" shows `tax_final_preview`'s live, unrecorded evaluation of that month (what computing it
 * now would produce), and "Posisi Tercatat" shows what `tax_period_position` says is actually on the books.
 * The Compute button is disabled whenever the live preview's own status is not `auto_determined` -- early
 * feedback only, the database re-checks the same condition itself (`tax_final_compute`'s own `CONFLICT`).
 */
export function TaxFinalScreen({
  period,
  preview,
  position,
  currency,
  entityId,
  entity,
}: {
  period: string;
  preview: FinalPreview;
  position: TaxPeriodPosition;
  currency: string;
  entityId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(
    computeFinalTaxAction,
    idleComputeFinalTaxFormState,
  );
  const previewStatus = preview.status as DeterminationStatus;
  const previewTone = DETERMINATION_STATUS_TONE[previewStatus];
  const canCompute = preview.status === "auto_determined";

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>PPh Final UMKM</h1>
          <p className="record-detail-counterparty">Masa Pajak {taxPeriodLabel(period)}</p>
        </div>
      </header>

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
                {reason}
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
          <h2 className="dashboard-section-title">Hitung Pajak Final</h2>
        </div>
        <form action={action} className="invoice-action-form">
          <input type="hidden" name="entity_id" value={entityId} />
          <input type="hidden" name="period" value={period} />
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}

          {!canCompute ? (
            <p className="hint">
              Belum bisa dihitung untuk masa ini ({DETERMINATION_STATUS_LABELS[previewStatus]}).
            </p>
          ) : null}

          {state.status === "error" ? (
            <p role="alert" className="error">
              {state.message}
            </p>
          ) : null}

          <button type="submit" className="btn-primary" disabled={pending || !canCompute}>
            {pending ? "Menghitung…" : "Hitung Pajak Final Bulan Ini"}
          </button>
        </form>
      </section>
    </div>
  );
}
