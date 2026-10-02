import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { DIFFERENCE_LABELS, taxPeriodLabel, type TaxType } from "@/domain/tax/tax";
import type { TaxPeriodPosition } from "@/schemas/tax";
import { formatShortDate } from "./format";

/**
 * Shared position report for the Withholding (`wht_pph23`) and PPN (`vat`) nav items (P13 unbuilt-screens
 * backlog, Step 09 §15, decision 235) -- one component, a `taxType`/`title` prop picks the role, the same
 * shared-screen-via-a-prop pattern decisions 198/176/225/229 already established. Unlike PPh Final UMKM
 * (decision 234), neither of these tax types has a determination step of its own to trigger from this screen
 * -- withholding and VAT are determined per document, automatically, at invoice/bill/expense time (Step 05)
 * -- so this is read-only: a period picker plus `tax_period_position`'s own figures. Paying, filing,
 * reconciling and evidence are deliberately deferred to their own "Filing & Evidence" increment, since
 * `tax_reconcile_period` needs `tax.mark_filed` (not `tax.view`) and groups naturally with `recordTaxPayment`/
 * `recordTaxFiling`/evidence rather than with either report screen.
 */
export function TaxPositionScreen({
  taxType,
  title,
  typeOptions,
  period,
  position,
  currency,
  entity,
}: {
  taxType: TaxType;
  title: string;
  /** When the nav item covers several tax types (Withholding), the ones the person can switch between. */
  typeOptions?: readonly { value: TaxType; label: string }[];
  period: string;
  position: TaxPeriodPosition;
  currency: string;
  entity: string | undefined;
}) {
  const ledgerHref = `/tax/ledger?type=${taxType}&period=${period}${entity ? `&entity=${encodeURIComponent(entity)}` : ""}`;

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>{title}</h1>
          <p className="record-detail-counterparty">Masa Pajak {taxPeriodLabel(period)}</p>
        </div>
      </header>

      <form method="get" className="list-search-form">
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}
        {typeOptions ? (
          <label>
            Jenis Pajak
            <select name="type" defaultValue={taxType}>
              {typeOptions.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
            </select>
          </label>
        ) : null}
        <label>
          Masa Pajak
          <input type="month" name="period" defaultValue={period.slice(0, 7)} />
        </label>
        <button type="submit" className="btn-secondary">
          Terapkan
        </button>
      </form>

      <p className="hint">
        <Link href={ledgerHref}>Lihat entri Buku Besar Pajak untuk masa ini →</Link>
      </p>

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
          {taxType === "vat" ? (
            <>
              <div>
                <dt>PPN Masukan Diakui</dt>
                <dd>{formatMoney(position.accrued_asset, currency)}</dd>
              </div>
              <div>
                <dt>PPN Masukan Terpakai</dt>
                <dd>{formatMoney(position.applied_asset, currency)}</dd>
              </div>
              <div>
                <dt>PPN Masukan Tersedia</dt>
                <dd>{formatMoney(position.asset_available, currency)}</dd>
              </div>
            </>
          ) : null}
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
    </div>
  );
}
