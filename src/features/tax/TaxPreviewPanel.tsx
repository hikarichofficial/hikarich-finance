import { formatMoney } from "@/domain/money/format";
import { DETERMINATION_STATUS_LABELS, TAX_KIND_LABELS, type TaxKind } from "@/domain/tax/tax";
import type { TaxPreview } from "@/schemas/tax";
import { TaxOverrideForm } from "./TaxOverrideForm";

function text(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

/**
 * What the tax engine would decide for a document that is not recognised yet (Step 05 §14-§15, decision
 * 262): each tax result with its amount, the reasons when a person must decide first, and the engine's own
 * explanation. With `tax.override` the OWNER can replace a result (override) with a reason and evidence;
 * the database requires a recent step-up. The explanation text comes from the database as written.
 */
export function TaxPreviewPanel({
  preview,
  currency,
  sourceType,
  sourceId,
  canOverride,
  next,
}: {
  preview: TaxPreview;
  currency: string;
  sourceType: "invoice" | "bill" | "expense";
  sourceId: string;
  canOverride: boolean;
  next: string;
}) {
  const inactive = preview.status === "not_configured";

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Perhitungan Pajak (sebelum dicatat)</h2>
      </div>
      {inactive ? (
        <p className="hint">
          Mesin pajak belum aktif untuk tanggal dokumen ini, jadi tidak ada pajak yang dihitung.
          Aktifkan di Pajak → Pengaturan Pajak.
        </p>
      ) : (
        <>
          <p className="hint">Status: {DETERMINATION_STATUS_LABELS[preview.status]}</p>
          {preview.status === "needs_review" ? (
            <div role="alert" className="error">
              <p>Dokumen ini belum bisa dicatat sampai hal berikut diselesaikan:</p>
              <ul>
                {preview.reasons.map((reason) => (
                  <li key={reason}>{reason}</li>
                ))}
              </ul>
            </div>
          ) : null}
          <dl className="record-summary-grid">
            {preview.results.map((result) => (
              <div key={result.kind}>
                <dt>
                  {TAX_KIND_LABELS[result.kind as TaxKind]} ·{" "}
                  {DETERMINATION_STATUS_LABELS[result.status]}
                </dt>
                <dd>{formatMoney(result.tax, currency)}</dd>
                {text(result.consequence) ? (
                  <p className="hint">{text(result.consequence)}</p>
                ) : null}
              </div>
            ))}
          </dl>
          {canOverride && preview.results.length > 0 ? (
            <TaxOverrideForm
              sourceType={sourceType}
              sourceId={sourceId}
              kinds={preview.results
                .filter((r) => r.kind !== "final_umkm" && r.kind !== "wht_pph21")
                .map((r) => ({ value: r.kind, label: TAX_KIND_LABELS[r.kind as TaxKind] }))}
              next={next}
            />
          ) : null}
        </>
      )}
    </section>
  );
}
