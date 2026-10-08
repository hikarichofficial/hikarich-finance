import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { LineTaxSummary } from "@/domain/tax/lineTaxSummary";

/**
 * Under the lines of a bill or expense: where the money goes (OWNER, 8 October 2026, second message). The document
 * total (the contract or receipt amount, VAT included) is the company's whole cost. The income tax (PPh) is taken
 * out of what the vendor or payee receives and the company pays it to the tax office, so the vendor receives the
 * total less the PPh. The PPh flows into Pajak > PPh Vendor (the monthly position) once the document is recorded.
 */
export function LineTaxSummaryBlock({
  summary,
  currency,
  total,
  detailHref,
}: {
  summary: LineTaxSummary;
  currency: string;
  /** The document total, VAT included: the company's whole cost. */
  total: string;
  /** The tax determination of the recorded document. */
  detailHref?: string;
}) {
  const charged = Number(summary.vatCharged);
  const creditable = Number(summary.vatCreditable);
  const cost = Number(summary.vatCost);
  const incomeTax = Number(summary.incomeTax);
  const received = (Number(total) - incomeTax).toFixed(4);
  return (
    <div className="line-tax-summary">
      <div className="tax-tiles">
        <div className="tax-tile">
          <span className="tax-tile-label">Diterima vendor</span>
          <strong className="tax-tile-value">{formatMoney(received, currency)}</strong>
          <span className="tax-tile-note">
            {charged > 0
              ? `Total dikurangi PPh. Sudah termasuk PPN dari vendor ${formatMoney(summary.vatCharged, currency)}.`
              : "Total dikurangi PPh. Tanpa PPN."}
          </span>
        </div>
        <div className="tax-tile">
          <span className="tax-tile-label">PPh disetor ke negara</span>
          <strong className="tax-tile-value">{formatMoney(summary.incomeTax, currency)}</strong>
          <span className="tax-tile-note">
            {incomeTax > 0
              ? "Diambil dari bayaran vendor, disetor PT ke negara. Masuk Pajak > PPh Vendor."
              : "Tidak ada PPh pada pengeluaran ini."}
          </span>
        </div>
        <div className="tax-tile tax-tile-total">
          <span className="tax-tile-label">Total biaya PT</span>
          <strong className="tax-tile-value">{formatMoney(total, currency)}</strong>
          <span className="tax-tile-note">Sama dengan jumlah di dokumen.</span>
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
