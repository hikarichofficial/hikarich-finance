import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { TurnoverReceivables } from "@/schemas/tax";

/**
 * Beside the PPh Final estimate: how much of the month's turnover is still unpaid by the customers (decision 426).
 * The tax is counted on the invoices at their issue date ("diterima atau diperoleh"), so a part-paid invoice counts
 * in full; this note explains the gap between the estimate and the bank. Read-only, nothing here changes the tax.
 * Shown only when something is unpaid.
 */
export function TurnoverReceivablesNote({
  receivables,
  currency,
  entity,
}: {
  receivables: TurnoverReceivables;
  currency: string;
  entity: string | undefined;
}) {
  if (receivables.unpaid_invoice_count === 0 || Number(receivables.turnover_unpaid) <= 0) {
    return null;
  }
  const qs = entity ? `&entity=${encodeURIComponent(entity)}` : "";
  return (
    <p className="hint">
      Dari penjualan {formatMoney(receivables.turnover_invoiced, currency)}, sebesar{" "}
      <strong>{formatMoney(receivables.turnover_unpaid, currency)}</strong> belum dibayar customer (
      {receivables.unpaid_invoice_count} invoice). Pajak dihitung dari invoice yang terbit, jadi
      bagian ini sudah ikut terhitung walau uangnya belum masuk.{" "}
      <Link href={`/sales/invoices?status=open${qs}`}>Lihat invoice belum lunas →</Link>
    </p>
  );
}
