import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { LineTaxSummary } from "@/domain/tax/lineTaxSummary";

/**
 * Under the lines of a bill or expense: where the money goes (OWNER, 8 October 2026). The vendor is paid the full
 * total, which includes the VAT the vendor or restaurant charged; the income tax (PPh) is the company's own cost on
 * top of that and goes to the tax office separately, so the company's total outlay is larger than the receipt. The
 * PPh flows into Pajak > PPh Vendor (the monthly position) once the document is recorded.
 */
export function LineTaxSummaryBlock({
  summary,
  currency,
  total,
  detailHref,
}: {
  summary: LineTaxSummary;
  currency: string;
  /** What the vendor is paid: the document total, VAT included. */
  total: string;
  /** The tax determination of the recorded document. */
  detailHref?: string;
}) {
  const charged = Number(summary.vatCharged);
  const creditable = Number(summary.vatCreditable);
  const cost = Number(summary.vatCost);
  const incomeTax = Number(summary.incomeTax);
  const outlay = (Number(total) + incomeTax).toFixed(4);
  return (
    <div className="line-tax-summary">
      <div className="tax-tiles">
        <div className="tax-tile">
          <span className="tax-tile-label">Dibayar ke vendor</span>
          <strong className="tax-tile-value">{formatMoney(total, currency)}</strong>
          <span className="tax-tile-note">
            {charged > 0
              ? `Sudah termasuk PPN dari vendor ${formatMoney(summary.vatCharged, currency)}.`
              : "Tanpa PPN."}
          </span>
        </div>
        <div className="tax-tile">
          <span className="tax-tile-label">PPh ke negara</span>
          <strong className="tax-tile-value">{formatMoney(summary.incomeTax, currency)}</strong>
          <span className="tax-tile-note">
            {incomeTax > 0
              ? "Beban pajak PT di atas harga, dibayar terpisah. Masuk Pajak > PPh Vendor."
              : "Tidak ada PPh pada pengeluaran ini."}
          </span>
        </div>
        <div className="tax-tile tax-tile-total">
          <span className="tax-tile-label">Total biaya PT</span>
          <strong className="tax-tile-value">{formatMoney(outlay, currency)}</strong>
          <span className="tax-tile-note">Dibayar ke vendor ditambah PPh ke negara.</span>
        </div>
      </div>
      {charged > 0 ? (
        <p className="tax-tile-foot">
          {creditable > 0 && cost > 0
            ? `PPN dari vendor: ${formatMoney(summary.vatCreditable, currency)} dikreditkan (mengurangi PPN yang Anda setor), ${formatMoney(summary.vatCost, currency)} menjadi biaya.`
            : creditable > 0
              ? "PPN dari vendor seluruhnya dikreditkan (mengurangi PPN yang Anda setor)."
              : "PPN dari vendor seluruhnya menjadi biaya perusahaan; bukan pajak yang Anda setor atau laporkan."}
        </p>
      ) : null}
      {detailHref ? (
        <p className="tax-tile-foot">
          <Link href={detailHref}>Lihat rincian penentuan pajak</Link>
        </p>
      ) : null}
    </div>
  );
}
