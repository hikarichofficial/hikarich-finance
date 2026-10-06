import { Decimal } from "@/domain/money/decimal";
import { formatMoney, formatMoneyExact, formatPlain } from "@/domain/money/format";
import { invoiceDocumentStatus } from "@/domain/sales/invoiceList";
import type { InvoiceDocument } from "@/schemas/sales";

/**
 * The invoice as a customer reads it (P13 Part 5, first increment; Step 11 -- Invoice/Receipt Visual
 * Specification §3-§7, §12-§13, FINAL/LOCKED): issuer, customer, lines, totals, payments received and the
 * payment instructions the OWNER chose to show. It renders only what the frozen document carries; internal
 * notes, ledger facts and tax identifiers never reach it. Print-clean: the print stylesheet removes chrome.
 *
 * The status badge reuses `invoiceDocumentStatus` (`src/domain/sales/invoiceList.ts`) rather than its own
 * copy of the same logic -- this view previously had its own local three-tone `statusLabel` (ok/warn/muted)
 * that drifted from the Invoice List/Detail screens' own five-tone badge (Step 09 §11: "Draft/Unpaid/
 * Partial/Paid/Overdue/Void"), so a customer could in principle see a different status word than the staff
 * screens showing the exact same invoice. `.doc-status-{tone}` (`globals.css`) is keyed on `InvoiceListTone`
 * directly now, so no local ok/warn/muted translation is needed either.
 *
 * The line-item cells (except the description, which stays an unlabelled full-width heading) carry a
 * `data-label` attribute (P13 Part 5, second increment; Step 11 §8, §22): unused on desktop/tablet, but on
 * a narrow screen `globals.css`'s mobile breakpoint turns each `<tr>` into a stacked card and reads the
 * label back out via `content: attr(data-label)`, so the line-item table never needs horizontal scrolling
 * to be read (§8: "Total/Outstanding and primary CTA remain easy to find without horizontal table
 * scrolling").
 */

type Party = Record<string, unknown> | null | undefined;

function field(party: Party, key: string): string | null {
  const value = party?.[key];
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

function addressLines(party: Party): string[] {
  const place = [field(party, "city"), field(party, "province"), field(party, "postal_code")]
    .filter(Boolean)
    .join(", ");
  return [field(party, "address_line"), place || null].filter((line): line is string =>
    Boolean(line),
  );
}

const DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

export function formatDocumentDate(isoDate: string): string {
  return DATE_FORMAT.format(new Date(`${isoDate}T00:00:00Z`));
}

/** The company logo (an embedded image the OWNER uploaded in Settings), shown beside the issuer's name. */
export function DocumentLogo({ logo }: { logo: string | null | undefined }) {
  if (!logo || !logo.startsWith("data:image/")) return null;
  return (
    // eslint-disable-next-line @next/next/no-img-element -- an embedded data: image, not optimizable
    <img className="doc-logo" src={logo} alt="" />
  );
}

export function InvoiceDocumentView({
  doc,
  logo,
  receiptHref,
}: {
  doc: InvoiceDocument;
  /** The company logo, when one is set (`entity_profiles.logo_data_url`). */
  logo?: string | null;
  /** Builds the link of a payment receipt from its number (customer page only). */
  receiptHref?: (receiptNumber: string) => string;
}) {
  const { issuer, customer, payment_instructions: instructions } = doc;
  const status = invoiceDocumentStatus(doc);
  const showDiscount = doc.lines.some((line) => line.discount_type !== "none");
  const showTax = !Decimal.parse(doc.tax_total).isZero();
  const showRefund = !Decimal.parse(doc.refunded).isZero();
  const brand = field(issuer, "brand_name") ?? field(issuer, "legal_name") ?? "Hikarich";
  const legal = field(issuer, "legal_name");
  // Only an https address becomes a link (the database refuses anything else; checked again here).
  const rawUrl = field(instructions, "payment_url");
  const paymentUrl = rawUrl?.startsWith("https://") ? rawUrl : null;

  return (
    <article
      className="doc"
      aria-label={`Invoice ${doc.invoice_number ?? ""}`}
      data-watermark={doc.status === "void" ? "void" : undefined}
    >
      <header className="doc-head">
        <div className="doc-issuer">
          <DocumentLogo logo={logo} />
          <h1 className="doc-brand">{brand}</h1>
          {legal && legal !== brand ? <p>{legal}</p> : null}
          {addressLines(issuer).map((line) => (
            <p key={line}>{line}</p>
          ))}
          {[field(issuer, "contact_email"), field(issuer, "contact_phone")]
            .filter(Boolean)
            .map((line) => (
              <p key={line}>{line}</p>
            ))}
        </div>
        <div className="doc-title">
          <p className="doc-kind">INVOICE</p>
          <p className="doc-number">{doc.invoice_number ?? "—"}</p>
          <span className={`doc-status doc-status-${status.tone}`}>{status.text}</span>
        </div>
      </header>

      <section className="doc-meta">
        <div>
          <h2>Ditagihkan kepada</h2>
          <p>
            <strong>{field(customer, "display_name")}</strong>
          </p>
          {field(customer, "legal_name") &&
          field(customer, "legal_name") !== field(customer, "display_name") ? (
            <p>{field(customer, "legal_name")}</p>
          ) : null}
          {addressLines(customer).map((line) => (
            <p key={line}>{line}</p>
          ))}
        </div>
        <dl>
          <dt>Tanggal invoice</dt>
          <dd>{formatDocumentDate(doc.issue_date)}</dd>
          <dt>Jatuh tempo</dt>
          <dd>{formatDocumentDate(doc.due_date)}</dd>
          <dt>Mata uang</dt>
          <dd>{doc.currency}</dd>
        </dl>
      </section>

      <table className="doc-lines">
        <thead>
          <tr>
            <th scope="col">Deskripsi</th>
            <th scope="col" className="num">
              Jumlah
            </th>
            <th scope="col" className="num">
              Harga
            </th>
            {showDiscount ? (
              <th scope="col" className="num">
                Diskon
              </th>
            ) : null}
            <th scope="col" className="num">
              Total
            </th>
          </tr>
        </thead>
        <tbody>
          {doc.lines.map((line) => (
            <tr key={line.line_no}>
              <td>{line.description}</td>
              <td className="num" data-label="Jumlah">
                {formatPlain(line.quantity)}
              </td>
              <td className="num" data-label="Harga">
                {formatMoneyExact(line.unit_price, doc.currency)}
              </td>
              {showDiscount ? (
                <td className="num" data-label="Diskon">
                  {line.discount_type === "none"
                    ? "—"
                    : formatMoney(line.discount_amount, doc.currency)}
                </td>
              ) : null}
              <td className="num" data-label="Total">
                {formatMoney(line.line_total, doc.currency)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>

      <dl className="doc-totals">
        <div>
          <dt>Subtotal</dt>
          <dd>{formatMoney(doc.subtotal, doc.currency)}</dd>
        </div>
        {showDiscount ? (
          <div>
            <dt>Diskon</dt>
            <dd>-{formatMoney(doc.discount_total, doc.currency)}</dd>
          </div>
        ) : null}
        {showTax ? (
          <div>
            <dt>PPN</dt>
            <dd>{formatMoney(doc.tax_total, doc.currency)}</dd>
          </div>
        ) : null}
        <div className="grand">
          <dt>Total</dt>
          <dd>{formatMoney(doc.total, doc.currency)}</dd>
        </div>
        {doc.payments.length > 0 ? (
          <>
            <div>
              <dt>Sudah dibayar</dt>
              <dd>{formatMoney(doc.settled, doc.currency)}</dd>
            </div>
            <div className="grand">
              <dt>Sisa tagihan</dt>
              <dd>{formatMoney(doc.outstanding, doc.currency)}</dd>
            </div>
          </>
        ) : null}
        {showRefund ? (
          <div className="refund">
            <dt>Dikembalikan (refund)</dt>
            <dd>{formatMoney(doc.refunded, doc.currency)}</dd>
          </div>
        ) : null}
      </dl>

      {doc.payments.length > 0 ? (
        <section className="doc-block">
          <h2>Pembayaran diterima</h2>
          <ul>
            {doc.payments.map((payment) => (
              <li key={payment.receipt_number}>
                {formatDocumentDate(payment.payment_date)} —{" "}
                {formatMoney(payment.amount, payment.currency)}{" "}
                {receiptHref ? (
                  <a href={receiptHref(payment.receipt_number)}>
                    Kwitansi {payment.receipt_number}
                  </a>
                ) : (
                  <span>Kwitansi {payment.receipt_number}</span>
                )}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      {instructions && doc.status === "issued" && doc.settlement_status !== "paid" ? (
        <section className="doc-block">
          <h2>Cara pembayaran</h2>
          {field(instructions, "institution_name") ? (
            <p>{field(instructions, "institution_name")}</p>
          ) : null}
          {field(instructions, "account_number") ? (
            <p className="account-number">{field(instructions, "account_number")}</p>
          ) : null}
          {field(instructions, "account_holder") ? (
            <p>a.n. {field(instructions, "account_holder")}</p>
          ) : null}
          {field(instructions, "channel_name") && !paymentUrl ? (
            <p>{field(instructions, "channel_name")}</p>
          ) : null}
          {paymentUrl ? (
            <p className="doc-pay">
              <a
                className="doc-pay-link"
                href={paymentUrl}
                target="_blank"
                rel="noopener noreferrer"
              >
                Bayar sekarang
              </a>
              <span className="doc-pay-url">{paymentUrl}</span>
            </p>
          ) : null}
          {doc.payment_note ? <p>{doc.payment_note}</p> : null}
        </section>
      ) : null}

      {doc.notes ? (
        <section className="doc-block">
          <h2>Catatan</h2>
          <p>{doc.notes}</p>
        </section>
      ) : null}
      {doc.terms ? (
        <section className="doc-block">
          <h2>Syarat &amp; ketentuan</h2>
          <p>{doc.terms}</p>
        </section>
      ) : null}
    </article>
  );
}
