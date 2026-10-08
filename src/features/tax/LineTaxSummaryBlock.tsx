import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { LineTaxSummary } from "@/domain/tax/lineTaxSummary";

/**
 * Under the lines of a bill or expense: what the taxes mean (OWNER, 8 October 2026). The VAT is the vendor's charge
 * and either becomes part of the cost or is credited; the withholding is the company's own tax to pay and report, so
 * it flows into Pajak > Pemotongan PPh (the monthly position) once the document is recorded.
 */
export function LineTaxSummaryBlock({
  summary,
  currency,
  detailHref,
}: {
  summary: LineTaxSummary;
  currency: string;
  /** The tax determination of the recorded document. */
  detailHref?: string;
}) {
  const charged = Number(summary.vatCharged);
  const creditable = Number(summary.vatCreditable);
  const cost = Number(summary.vatCost);
  const withheld = Number(summary.withheld);
  return (
    <div className="line-tax-summary">
      <p>
        <strong>PPN dari vendor: {formatMoney(summary.vatCharged, currency)}.</strong>{" "}
        {charged <= 0
          ? "Tidak ada PPN pada pengeluaran ini."
          : creditable > 0 && cost > 0
            ? `${formatMoney(summary.vatCreditable, currency)} dikreditkan (mengurangi PPN yang Anda setor), ${formatMoney(summary.vatCost, currency)} menjadi bagian dari biaya.`
            : creditable > 0
              ? "Seluruhnya dikreditkan (mengurangi PPN yang Anda setor)."
              : "Seluruhnya menjadi bagian dari biaya perusahaan; bukan pajak yang Anda setor atau laporkan."}
      </p>
      <p>
        <strong>PPh yang dipotong: {formatMoney(summary.withheld, currency)}.</strong>{" "}
        {withheld > 0
          ? "Ditahan dari pembayaran ke vendor, lalu menjadi pajak yang Anda setor dan laporkan: masuk ke Pajak > Pemotongan PPh pada ringkasan bulanan."
          : "Tidak ada potongan PPh pada pengeluaran ini."}
      </p>
      {detailHref ? (
        <p>
          <Link href={detailHref}>Lihat rincian penentuan pajak</Link>
        </p>
      ) : null}
    </div>
  );
}
