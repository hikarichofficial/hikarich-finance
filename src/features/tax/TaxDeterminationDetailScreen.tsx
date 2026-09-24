import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { DETERMINATION_STATUS_LABELS, DETERMINATION_STATUS_TONE } from "@/domain/tax/tax";
import { formatTaxRate, taxKindLabel, taxSourceDocumentHref } from "@/domain/tax/taxLedgerList";
import type { TaxDeterminationRow } from "@/schemas/tax";
import { formatShortDate } from "./format";

const SOURCE_TYPE_LABELS: Readonly<Record<string, string>> = {
  invoice: "Faktur Penjualan",
  bill: "Tagihan Pembelian",
  expense: "Beban",
};

/**
 * Tax Determination Detail (P13 Part 3e, Step 09 §15): "what tax, why, rule/version, basis, rate/formula,
 * amount and source transaction" for one document. `listTaxDeterminations` returns every determination ever
 * made for it, newest first, since a document can carry more than one tax kind at once (a bill can owe both
 * input VAT and PPh 23 withholding) and a superseded row stays as visible history rather than being deleted or
 * edited (Step 05 §12, §15). Live determinations (not yet superseded) are shown first; a superseded one is
 * kept underneath as history, collapsed to its own section so the page reads current-result-first.
 */
export function TaxDeterminationDetailScreen({
  sourceType,
  sourceId,
  determinations,
  currency,
  entity,
  backHref,
}: {
  sourceType: string;
  sourceId: string;
  determinations: readonly TaxDeterminationRow[];
  currency: string;
  entity: string | undefined;
  backHref: string;
}) {
  const live = determinations.filter((d) => d.superseded_at === null);
  const history = determinations.filter((d) => d.superseded_at !== null);
  const documentHref = taxSourceDocumentHref(sourceType, sourceId, entity);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke buku besar pajak</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak · Penentuan</p>
          <h1>{SOURCE_TYPE_LABELS[sourceType] ?? sourceType}</h1>
          <p className="record-detail-counterparty">
            {documentHref ? (
              <Link href={documentHref}>Lihat dokumen sumber →</Link>
            ) : (
              "Dokumen sumber ini belum memiliki layar detail tersendiri."
            )}
          </p>
        </div>
      </header>

      {determinations.length === 0 ? (
        <p className="dashboard-empty">Belum ada penentuan pajak untuk dokumen ini.</p>
      ) : null}

      {live.map((determination) => (
        <DeterminationSection
          key={determination.id}
          determination={determination}
          currency={currency}
        />
      ))}

      {history.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Riwayat</h2>
          </div>
          {history.map((determination) => (
            <DeterminationSection
              key={determination.id}
              determination={determination}
              currency={currency}
            />
          ))}
        </section>
      ) : null}
    </div>
  );
}

function DeterminationSection({
  determination,
  currency,
}: {
  determination: TaxDeterminationRow;
  currency: string;
}) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">{taxKindLabel(determination.tax_kind)}</h2>
        <span
          className={`status-badge status-badge-${DETERMINATION_STATUS_TONE[determination.status]}`}
        >
          {DETERMINATION_STATUS_LABELS[determination.status]}
        </span>
      </div>

      <dl className="record-summary-grid">
        <div>
          <dt>Tanggal Peristiwa</dt>
          <dd>{formatShortDate(determination.event_date)}</dd>
        </div>
        <div>
          <dt>Masa Pajak</dt>
          <dd>{formatShortDate(determination.tax_period)}</dd>
        </div>
        <div>
          <dt>Dasar Pengenaan</dt>
          <dd>{formatMoney(determination.base_amount, currency)}</dd>
        </div>
        <div>
          <dt>Tarif</dt>
          <dd>{formatTaxRate(determination.rate)}</dd>
        </div>
        <div>
          <dt>Jumlah Pajak</dt>
          <dd>{formatMoney(determination.tax_amount, currency)}</dd>
        </div>
        {determination.computed_tax_amount !== null ? (
          <div>
            <dt>Hasil Mesin Sebelum Diubah</dt>
            <dd>{formatMoney(determination.computed_tax_amount, currency)}</dd>
          </div>
        ) : null}
        {determination.consequence ? (
          <div>
            <dt>Konsekuensi</dt>
            <dd>{determination.consequence}</dd>
          </div>
        ) : null}
        <div>
          <dt>Ditinjau Petugas Pajak</dt>
          <dd>{determination.confirmed ? "Ya" : "Belum"}</dd>
        </div>
        {determination.superseded_reason ? (
          <div>
            <dt>Alasan Digantikan</dt>
            <dd>{determination.superseded_reason}</dd>
          </div>
        ) : null}
      </dl>

      {determination.rules.length > 0 ? (
        <div className="dashboard-subsection">
          <h3 className="dashboard-section-title">Aturan yang Diterapkan</h3>
          <ul className="record-activity-list">
            {determination.rules.map((rule) => (
              <li key={rule.rule_id} className="record-activity-item">
                <span className="status-badge status-badge-neutral">
                  {rule.code} v{rule.rule_version}
                </span>
                <span className="record-activity-date">
                  Berlaku sejak {formatShortDate(rule.effective_from)}
                  {rule.source_ref ? ` · ${rule.source_ref}` : ""}
                </span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {determination.components.length > 0 ? (
        <div className="dashboard-subsection">
          <h3 className="dashboard-section-title">Rincian Perhitungan</h3>
          <ul className="record-activity-list">
            {determination.components.map((component, index) => (
              <li key={`${component.label}-${index}`} className="record-activity-item">
                <span>{component.label}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}

      {determination.trace.length > 0 ? (
        <div className="dashboard-subsection">
          <h3 className="dashboard-section-title">Penjelasan Mesin Pajak</h3>
          <ul className="record-activity-list">
            {determination.trace.map((entry) => (
              <li key={entry.n} className="record-activity-item">
                <span>{entry.text}</span>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </section>
  );
}
