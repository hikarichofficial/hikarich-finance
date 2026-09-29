import { formatMoney } from "@/domain/money/format";
import { paymentReceiptStatus } from "@/domain/sales/receiptDocument";
import type { ReceiptDocument } from "@/schemas/sales";
import { formatDocumentDate } from "./InvoiceDocumentView";

/**
 * A payment receipt as the payer reads it (P13 Part 5, first increment; Step 11 §10, FINAL/LOCKED): what was
 * received, when, and which invoices it settled. A reversed payment is shown as reversed, never hidden.
 * Refundable balances and internal facts are not part of it. The status badge reuses `paymentReceiptStatus`
 * (`src/domain/sales/receiptDocument.ts`) and the shared `.doc-status-{tone}` classes (`globals.css`,
 * keyed on `InvoiceListTone`) instead of this view's own local `ok`/`muted` mapping.
 */

type Party = Record<string, unknown> | null | undefined;

function field(party: Party, key: string): string | null {
  const value = party?.[key];
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function ReceiptDocumentView({ receipt }: { receipt: ReceiptDocument }) {
  const brand =
    field(receipt.issuer, "brand_name") ?? field(receipt.issuer, "legal_name") ?? "Hikarich";
  const method = receipt.method;
  const status = paymentReceiptStatus(receipt);
  return (
    <article className="doc" aria-label={`Kwitansi ${receipt.receipt_number}`}>
      <header className="doc-head">
        <div>
          <h1 className="doc-brand">{brand}</h1>
          {field(receipt.issuer, "legal_name") && field(receipt.issuer, "legal_name") !== brand ? (
            <p>{field(receipt.issuer, "legal_name")}</p>
          ) : null}
        </div>
        <div className="doc-title">
          <p className="doc-kind">KWITANSI</p>
          <p className="doc-number">{receipt.receipt_number}</p>
          <span className={`doc-status doc-status-${status.tone}`}>{status.text}</span>
        </div>
      </header>

      <section className="doc-meta">
        <div>
          <h2>Diterima dari</h2>
          <p>
            <strong>{field(receipt.customer, "display_name")}</strong>
          </p>
        </div>
        <dl>
          <dt>Tanggal</dt>
          <dd>{formatDocumentDate(receipt.payment_date)}</dd>
          <dt>Jumlah</dt>
          <dd>{formatMoney(receipt.amount, receipt.currency)}</dd>
          {receipt.reference ? (
            <>
              <dt>Referensi</dt>
              <dd>{receipt.reference}</dd>
            </>
          ) : null}
        </dl>
      </section>

      {receipt.allocations.length > 0 ? (
        <section className="doc-block">
          <h2>Untuk pembayaran faktur</h2>
          <ul>
            {receipt.allocations.map((item, index) => (
              <li key={index}>
                {typeof item.invoice_number === "string" ? item.invoice_number : "—"} —{" "}
                {typeof item.amount === "string" ? formatMoney(item.amount, receipt.currency) : "—"}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {field(method, "institution") || field(method, "channel") ? (
        <section className="doc-block">
          <h2>Diterima melalui</h2>
          <p>
            {[
              field(method, "channel"),
              field(method, "institution"),
              field(method, "account_masked"),
            ]
              .filter(Boolean)
              .join(" · ")}
          </p>
        </section>
      ) : null}
    </article>
  );
}
