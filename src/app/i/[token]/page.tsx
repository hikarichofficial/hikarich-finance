import type { Metadata } from "next";
import { notFound } from "next/navigation";
import { formatDecimal } from "@/domain/money/format";
import { currencyScale } from "@/domain/money/currency";
import { InvoiceDocumentView } from "@/features/sales/InvoiceDocumentView";
import { PrintButton } from "@/features/sales/PrintButton";
import { PublicClaimForm } from "@/features/sales/PublicClaimForm";
import { getPublicInvoice } from "@/services/sales/public";

export const metadata: Metadata = {
  title: "Faktur",
  robots: { index: false, follow: false },
  referrer: "no-referrer",
};

/** Today's date in the business time zone, as YYYY-MM-DD (the database re-checks the date it receives). */
function businessToday(): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone: "Asia/Jakarta",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(new Date());
}

export default async function PublicInvoicePage({
  params,
}: {
  params: Promise<{ token: string }>;
}) {
  const { token } = await params;
  const view = await getPublicInvoice(token);
  if (view.state !== "ok") notFound();
  const { invoice } = view;

  const receiptHref = (number: string) => `/i/${token}/receipt?no=${encodeURIComponent(number)}`;
  const outstanding = formatDecimal(invoice.outstanding, currencyScale(invoice.currency));

  return (
    <main className="doc-page">
      <div className="doc-actions no-print">
        <PrintButton />
      </div>
      <InvoiceDocumentView doc={invoice} receiptHref={receiptHref} />
      <section className="doc-claim no-print">
        {view.pending_claim ? (
          <p role="status" className="notice">
            Konfirmasi pembayaran Anda sedang kami periksa.
          </p>
        ) : null}
        {view.can_claim ? (
          <PublicClaimForm
            token={token}
            today={businessToday()}
            minDate={invoice.issue_date}
            outstanding={outstanding}
          />
        ) : null}
      </section>
    </main>
  );
}
