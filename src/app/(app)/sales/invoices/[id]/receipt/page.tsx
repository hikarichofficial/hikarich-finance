import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getInvoiceDocument, getPaymentReceipt, listPayments } from "@/services/sales/sales";
import { getEntityLogo } from "@/services/settings/settings";
import { PrintButton } from "@/features/sales/PrintButton";
import { ReceiptDocumentView } from "@/features/sales/ReceiptDocumentView";

/**
 * The receipt of one payment of an invoice, opened from the invoice's own page (decision 330): the same
 * document the customer reads at `/i/<token>/receipt?no=...`, with the same back link and print button.
 * The receipt number must belong to THIS invoice (it is looked up in the invoice's own payments), so the
 * page cannot be used to open another invoice's receipt by editing the address.
 */
export default async function InvoiceReceiptPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string; no?: string }>;
}) {
  const { id } = await params;
  const { entity, no } = await searchParams;
  const { membership } = await requirePermission("invoices.view", { entityCode: entity });

  const doc = await getInvoiceDocument(id).catch(() => null);
  if (!doc || !no || !doc.payments.some((payment) => payment.receipt_number === no)) notFound();

  const rows = await listPayments(membership.entity_id, { invoiceId: id });
  const payment = rows.find((row) => row.payment_number === no);
  if (!payment) notFound();

  const [receipt, logo] = await Promise.all([
    getPaymentReceipt(payment.payment_id).catch(() => null),
    getEntityLogo(membership.entity_id),
  ]);
  if (!receipt) notFound();

  const invoiceHref = entity
    ? `/sales/invoices/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/invoices/${id}`;

  return (
    <main className="doc-page">
      <div className="doc-actions no-print">
        <a href={invoiceHref}>← Kembali ke invoice</a>
        <PrintButton />
      </div>
      <ReceiptDocumentView receipt={receipt} logo={logo} />
    </main>
  );
}
