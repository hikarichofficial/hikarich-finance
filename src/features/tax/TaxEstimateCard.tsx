import Link from "next/link";
import { translateReason } from "@/domain/authz/translateReason";
import { formatMoney } from "@/domain/money/format";
import { taxPeriodLabel } from "@/domain/tax/tax";
import type { FinalPreview } from "@/schemas/tax";

/**
 * Perkiraan PPh Final UMKM bulan berjalan (decision 342). The figure comes from `tax_final_estimate`: the same rule
 * applied to the invoices issued so far this month, recomputed on every read, never recorded. It becomes the final
 * tax only after the month has ended and is computed on the PPh Final screen. Nothing is shown when the Entity is
 * not on the final regime or the tax engine is not active yet.
 */
export function TaxEstimateCard({
  estimate,
  period,
  currency,
  entity,
  linkToFinal,
}: {
  estimate: FinalPreview;
  period: string;
  currency: string;
  entity: string | undefined;
  linkToFinal: boolean;
}) {
  if (estimate.status === "not_applicable" || estimate.status === "not_configured") return null;
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Perkiraan Pajak Bulan Berjalan</h2>
        <span className="status-badge status-badge-progress">Perkiraan</span>
      </div>
      {estimate.status === "auto_determined" ? (
        <>
          <dl className="record-summary-grid">
            <div>
              <dt>PPh Final UMKM · {taxPeriodLabel(period)}</dt>
              <dd>{formatMoney(estimate.tax, currency)}</dd>
            </div>
            {estimate.turnover_month !== undefined ? (
              <div>
                <dt>Penjualan bulan ini sampai hari ini</dt>
                <dd>{formatMoney(estimate.turnover_month, currency)}</dd>
              </div>
            ) : null}
          </dl>
          <p className="hint">
            Angka ini otomatis bertambah setiap ada invoice terbit. Setelah bulan berakhir, pajaknya
            dihitung final di menu PPh Final dan baru tercatat sebagai kewajiban.
          </p>
        </>
      ) : (
        <ul className="dashboard-list">
          {estimate.reasons.map((reason, i) => (
            <li key={i} className="dashboard-list-item-detail">
              {translateReason(reason) ?? reason}
            </li>
          ))}
        </ul>
      )}
      {linkToFinal ? (
        <p className="hint">
          <Link href={`/tax/pph${qs}`}>Buka PPh Final →</Link>
        </p>
      ) : null}
    </section>
  );
}
