import { translateReason } from "@/domain/authz/translateReason";
import { formatMoney } from "@/domain/money/format";
import { DETERMINATION_STATUS_LABELS, TAX_KIND_LABELS, type TaxKind } from "@/domain/tax/tax";
import type { TaxPreview } from "@/schemas/tax";
import { TaxOverrideForm, TaxOverrideWithdrawForm } from "./TaxOverrideForm";

function text(value: unknown): string | null {
  return typeof value === "string" && value !== "" ? value : null;
}

/** The id of the override behind a result, when the engine reports one (`override.id`; results are loose). */
function overrideIdOf(result: unknown): string | null {
  const override = (result as Record<string, unknown>).override;
  if (typeof override !== "object" || override === null) return null;
  return text((override as Record<string, unknown>).id);
}

/**
 * What the tax engine would decide for a document that is not recognised yet (Step 05 §14-§15, decision
 * 262): each tax result with its amount, the reasons when a person must decide first, and the engine's own
 * explanation. With `tax.override` the OWNER can replace a result (override) with a reason and evidence;
 * the database requires a recent step-up. The explanation text comes from the database in English and is
 * shown translated by `translateReason` (display only; a sentence nobody wrote a template for stays as written).
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
          {sourceType !== "invoice" ? (
            <p className="hint">
              <strong>PPN masukan</strong> adalah PPN yang ditagih vendor atau restoran di struk.{" "}
              <strong>PPh</strong> diambil dari bayaran vendor lalu disetor PT ke negara, jadi biaya
              PT tetap sebesar jumlah di dokumen.
            </p>
          ) : null}
          {preview.status === "needs_review" ? (
            <div role="alert" className="error">
              <p>Dokumen ini belum bisa dicatat sampai hal berikut diselesaikan:</p>
              <ul>
                {preview.reasons.map((reason) => (
                  <li key={reason}>{translateReason(reason) ?? reason}</li>
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
                {result.status === "overridden" ? (
                  <p className="hint">
                    Angka ini hasil koreksi manual; hitungan otomatis sebelumnya tidak dipakai.
                  </p>
                ) : text(result.consequence) ? (
                  <p className="hint">
                    {translateReason(text(result.consequence) ?? "") ?? text(result.consequence)}
                  </p>
                ) : null}
                {canOverride && result.status === "overridden" && overrideIdOf(result) ? (
                  <TaxOverrideWithdrawForm
                    overrideId={overrideIdOf(result) ?? ""}
                    label={TAX_KIND_LABELS[result.kind as TaxKind]}
                    next={next}
                  />
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
