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
        <h2 className="dashboard-section-title">Perkiraan PPh Final · {taxPeriodLabel(period)}</h2>
        <span className="status-badge status-badge-progress">Perkiraan</span>
      </div>
      {estimate.status === "auto_determined" ? (
        <>
          <div className="tax-split">
            <div className="tax-split-item">
              <span>PPh Final UMKM</span>
              <strong>{formatMoney(estimate.tax, currency)}</strong>
            </div>
            {estimate.turnover_month !== undefined ? (
              <div className="tax-split-item">
                <span>Penjualan bulan ini</span>
                <strong>{formatMoney(estimate.turnover_month, currency)}</strong>
              </div>
            ) : null}
          </div>
          <p className="hint">
            Bertambah otomatis tiap invoice terbit. Final setelah bulan berakhir.
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
