import "server-only";
import { randomUUID } from "node:crypto";
import { getServerEnv } from "@/lib/env";
import { formatMoney } from "@/domain/money/format";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";
import { getContact } from "@/services/contacts/contacts";
import { recordEmailDelivery } from "@/services/email/deliveries";
import { emailDeliveryEnabled, sendEmail } from "@/services/email/resend";
import type { ReceiptDocument } from "@/schemas/sales";
import { getInvoiceLink, getPaymentReceipt, regenerateInvoiceLink } from "./sales";

/**
 * "Kirim Bukti Pembayaran via Email" (OWNER, 5 October 2026). The receipt is the one the customer already has
 * a public page for (`/i/<token>/receipt?no=<payment number>`), reached through the public link of an invoice
 * the payment settled -- so this reuses the invoice's own link (`getInvoiceLink`/`regenerateInvoiceLink`),
 * never a second kind of link, and revoking that link also closes the receipt page. Every figure comes from
 * `payment_receipt_document`.
 */

export type SendReceiptEmailResult =
  | { outcome: "sent"; to: string }
  | { outcome: "not_configured" }
  | { outcome: "no_recipient" }
  | { outcome: "not_confirmed" }
  | { outcome: "no_invoice" }
  | { outcome: "failed"; detail?: string };

function esc(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function partyText(party: unknown, key: string): string | null {
  if (!party || typeof party !== "object") return null;
  const value = (party as Record<string, unknown>)[key];
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

const DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

function receiptEmailHtml(receipt: ReceiptDocument, link: string, issuerName: string): string {
  const customerName = partyText(receipt.customer, "display_name") ?? "Pelanggan";
  const amount = formatMoney(receipt.amount, receipt.currency);
  const date = DATE_FORMAT.format(new Date(`${receipt.payment_date}T00:00:00Z`));
  return `<!doctype html>
<html lang="id">
  <body style="font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; background: #f4f4f5; margin: 0; padding: 24px;">
    <table role="presentation" width="100%" style="max-width: 560px; margin: 0 auto; background: #ffffff; border-radius: 8px; overflow: hidden;">
      <tr>
        <td style="background: #0f172a; padding: 20px 28px;">
          <span style="color: #ffffff; font-size: 18px; font-weight: bold;">${esc(issuerName)}</span>
        </td>
      </tr>
      <tr>
        <td style="padding: 28px;">
          <p style="margin: 0 0 16px;">Halo ${esc(customerName)},</p>
          <p style="margin: 0 0 16px;">
            Pembayaran Anda sejumlah <b>${esc(amount)}</b> pada <b>${esc(date)}</b> sudah kami terima.
            Terima kasih. Nomor bukti pembayaran: <b>${esc(receipt.receipt_number)}</b>.
          </p>
          <p style="margin: 0 0 24px;">
            <a href="${esc(link)}"
               style="display: inline-block; background: #0f172a; color: #ffffff; text-decoration: none;
                      padding: 12px 24px; border-radius: 6px; font-weight: bold;">
              Lihat Bukti Pembayaran
            </a>
          </p>
          <p style="margin: 0; font-size: 13px; color: #6b7280;">
            Jika tombol di atas tidak berfungsi, salin tautan berikut ke browser Anda:<br />
            <a href="${esc(link)}" style="color: #2563eb;">${esc(link)}</a>
          </p>
        </td>
      </tr>
    </table>
  </body>
</html>`;
}

/** Sends (or re-sends) the receipt e-mail of one confirmed payment. `recipientOverride` is the address typed in
 * the form, preferred over the customer's own e-mail on file. */
export async function sendPaymentReceiptEmail(
  paymentId: string,
  recipientOverride?: string,
): Promise<SendReceiptEmailResult> {
  if (!emailDeliveryEnabled()) return { outcome: "not_configured" };
  const id = uuidResultSchema.parse(paymentId);

  const receipt = await getPaymentReceipt(id);
  if (receipt.status !== "confirmed") return { outcome: "not_confirmed" };

  const supabase = await createSupabaseServerClient();
  const { data: payment } = await supabase
    .from("payments")
    .select("entity_id, customer_id")
    .eq("id", id)
    .maybeSingle();
  if (!payment) return { outcome: "failed", detail: "payment not found" };
  const { data: allocation } = await supabase
    .from("payment_allocations")
    .select("invoice_id")
    .eq("payment_id", id)
    .eq("status", "active")
    .limit(1)
    .maybeSingle();
  if (!allocation) return { outcome: "no_invoice" };
  const invoiceId = String(allocation.invoice_id);

  const contact = payment.customer_id ? await getContact(String(payment.customer_id)) : null;
  const to = (recipientOverride ?? contact?.email ?? "").trim();
  if (!to) return { outcome: "no_recipient" };

  const existingLink = await getInvoiceLink(invoiceId);
  const token =
    existingLink && existingLink.status === "active"
      ? existingLink.token
      : await regenerateInvoiceLink({ invoice_id: invoiceId, idempotency_key: randomUUID() });
  const appUrl = getServerEnv().APP_URL.replace(/\/+$/, "");
  const link = `${appUrl}/i/${token}/receipt?no=${encodeURIComponent(receipt.receipt_number)}`;
  const issuerName =
    partyText(receipt.issuer, "brand_name") ??
    partyText(receipt.issuer, "legal_name") ??
    "Hikarich";

  const result = await sendEmail({
    to,
    subject: `Bukti pembayaran ${receipt.receipt_number} dari ${issuerName}`,
    html: receiptEmailHtml(receipt, link, issuerName),
  });
  await recordEmailDelivery({
    entity_id: String(payment.entity_id),
    kind: "payment_receipt",
    target_id: id,
    recipient: to,
    status: result.sent ? "sent" : "failed",
    detail: result.detail,
  });
  if (!result.sent) return { outcome: "failed", detail: result.detail };
  return { outcome: "sent", to };
}
