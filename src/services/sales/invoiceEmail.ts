import "server-only";
import { randomUUID } from "node:crypto";
import { getServerEnv } from "@/lib/env";
import { formatMoney } from "@/domain/money/format";
import { getContact } from "@/services/contacts/contacts";
import { emailDeliveryEnabled, sendEmail } from "@/services/email/resend";
import { recordEmailDelivery } from "@/services/email/deliveries";
import type { InvoiceDocument } from "@/schemas/sales";
import {
  getInvoiceDocument,
  getInvoiceLink,
  getInvoiceOwner,
  regenerateInvoiceLink,
} from "./sales";

/**
 * "Kirim Invoice via Email" (decision 279's open item, OWNER-confirmed: Resend, kept alongside -- not
 * instead of -- the existing public-link share). Only an issued invoice has a stable public link to send
 * (the same `status === "issued"` gate `CopyLinkForm`/`invoices.regenerate_link` already use), so this
 * reuses `getInvoiceLink`/`regenerateInvoiceLink` exactly as `ensureInvoiceLinkAction` does -- never a
 * second kind of link, never a figure recomputed outside `invoice_document`.
 */

export type SendInvoiceEmailResult =
  | { outcome: "sent"; to: string }
  | { outcome: "not_configured" }
  | { outcome: "no_recipient" }
  | { outcome: "not_issued" }
  | { outcome: "failed"; detail?: string };

function partyText(party: unknown, key: string): string | null {
  if (!party || typeof party !== "object") return null;
  const value = (party as Record<string, unknown>)[key];
  return typeof value === "string" && value.trim() !== "" ? value.trim() : null;
}

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

function shortDate(isoDate: string): string {
  return SHORT_DATE_FORMAT.format(new Date(`${isoDate}T00:00:00Z`));
}

function invoiceEmailHtml(doc: InvoiceDocument, link: string, issuerName: string): string {
  const customerName = partyText(doc.customer, "display_name") ?? "Pelanggan";
  const total = formatMoney(doc.total, doc.currency);
  const paid = doc.settlement_status === "paid";
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
            ${
              paid
                ? `Invoice <b>${esc(doc.invoice_number ?? "-")}</b> sejumlah <b>${esc(total)}</b> sudah <b>lunas</b>. Terima kasih atas pembayaran Anda.`
                : `Invoice <b>${esc(doc.invoice_number ?? "-")}</b> sejumlah <b>${esc(total)}</b> telah terbit, dengan jatuh tempo pembayaran pada <b>${esc(shortDate(doc.due_date))}</b>.`
            }
          </p>
          <p style="margin: 0 0 24px;">
            <a href="${esc(link)}"
               style="display: inline-block; background: #0f172a; color: #ffffff; text-decoration: none;
                      padding: 12px 24px; border-radius: 6px; font-weight: bold;">
              ${paid ? "Lihat Invoice &amp; Kwitansi" : "Lihat &amp; Bayar Invoice"}
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

function esc(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Sends (or re-sends) the issued invoice's public-link email. `recipientOverride` is the address the
 * person typed in the send form -- always preferred over the customer's own `contacts.email` on file, so a
 * one-off address never needs to be saved to the contact first. */
export async function sendInvoiceEmail(
  invoiceId: string,
  recipientOverride?: string,
): Promise<SendInvoiceEmailResult> {
  if (!emailDeliveryEnabled()) return { outcome: "not_configured" };

  const doc = await getInvoiceDocument(invoiceId);
  if (doc.status !== "issued") return { outcome: "not_issued" };

  const owner = await getInvoiceOwner(invoiceId);
  if (!owner) return { outcome: "failed", detail: "invoice not found" };
  const contact = await getContact(owner.customer_id);
  const to = (recipientOverride ?? contact?.email ?? "").trim();
  if (!to) return { outcome: "no_recipient" };

  const existingLink = await getInvoiceLink(invoiceId);
  const token =
    existingLink && existingLink.status === "active"
      ? existingLink.token
      : await regenerateInvoiceLink({ invoice_id: invoiceId, idempotency_key: randomUUID() });

  const appUrl = getServerEnv().APP_URL.replace(/\/+$/, "");
  const link = `${appUrl}/i/${token}`;
  const issuerName =
    partyText(doc.issuer, "brand_name") ?? partyText(doc.issuer, "legal_name") ?? "Hikarich";

  const result = await sendEmail({
    to,
    subject: `Invoice ${doc.invoice_number ?? ""} dari ${issuerName}`.trim(),
    html: invoiceEmailHtml(doc, link, issuerName),
  });
  await recordEmailDelivery({
    entity_id: owner.entity_id,
    kind: "invoice",
    target_id: invoiceId,
    recipient: to,
    status: result.sent ? "sent" : "failed",
    detail: result.detail,
  });
  if (!result.sent) return { outcome: "failed", detail: result.detail };
  return { outcome: "sent", to };
}
