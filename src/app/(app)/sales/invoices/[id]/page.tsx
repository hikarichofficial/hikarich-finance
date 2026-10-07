import { AttachmentsSection } from "@/features/documents/AttachmentsSection";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getInvoiceDocument,
  getInvoiceOwner,
  listInvoicePendingClaims,
} from "@/services/sales/sales";
import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { formatShortDate } from "@/features/sales/format";
import { getEntityLogo, getInvoiceLayout } from "@/services/settings/settings";
import { getContact } from "@/services/contacts/contacts";
import { emailDeliveryEnabled } from "@/services/email/resend";
import { listEmailDeliveries } from "@/services/email/deliveries";
import { EmailHistory } from "@/features/sales/EmailHistory";
import { getMoneyControl } from "@/services/money/money";
import { previewDocumentTax } from "@/services/tax/tax";
import { TaxPreviewPanel } from "@/features/tax/TaxPreviewPanel";
import { InvoiceDetailScreen } from "@/features/sales/InvoiceDetailScreen";
import { todayInBusinessZone } from "@/lib/time";

/** Invoice Detail (P13 Part 3a, Step 09 §10, §11). Permission to act is read off the currently active
 * Entity (`?entity=`), the same per-page pattern every other screen uses (DECISIONS 158); the database
 * still re-checks every action against the invoice's own actual Entity regardless of what is active here.
 * Send Invoice via Email (decision 279's open item) is loaded only when the invoice is issued and the
 * caller holds `invoices.regenerate_link` (the same gate "Salin Tautan Publik" already uses, since both
 * share one public link) -- `getInvoiceOwner`/`getContact` are the same lookups `recordInvoicePaymentAction`
 * already makes for the customer, and `emailDeliveryEnabled()` just reads whether the OWNER has set up
 * Resend, never a network call. */
export default async function InvoiceDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });

  const doc = await getInvoiceDocument(id).catch(() => null);
  if (!doc) notFound();

  const entityId = membership.entity_id;
  const canRecordPayment =
    can(access, entityId, "invoices.confirm_payment") &&
    doc.status === "issued" &&
    Number(doc.outstanding) > 0;
  const backHref = entity
    ? `/sales/invoices?entity=${encodeURIComponent(entity)}`
    : "/sales/invoices";
  const selfHref = entity
    ? `/sales/invoices/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/invoices/${id}`;
  const claimsHref = entity
    ? `/sales/claims?entity=${encodeURIComponent(entity)}`
    : "/sales/claims";
  const canManageLink = can(access, entityId, "invoices.regenerate_link");
  const isIssued = doc.status === "issued";

  // Everything below is independent of each other: fetch it all at once instead of one after another
  // (every await in a row costs a full round trip to the database; decision 323).
  const [accounts, taxPreview, logo, layout, defaultEmail, claims, emailRows] = await Promise.all([
    canRecordPayment ? getMoneyControl(entityId).catch(() => []) : Promise.resolve([]),
    doc.status === "draft"
      ? previewDocumentTax({ source_type: "invoice", source_id: id }).catch(() => null)
      : Promise.resolve(null),
    getEntityLogo(entityId),
    doc.status === "draft" ? getInvoiceLayout(entityId) : Promise.resolve(null),
    isIssued && canManageLink
      ? getInvoiceOwner(id)
          .then((owner) => (owner ? getContact(owner.customer_id) : null))
          .then((contact) => contact?.email ?? null)
          .catch(() => null)
      : Promise.resolve(null),
    isIssued ? listInvoicePendingClaims(id).catch(() => []) : Promise.resolve([]),
    isIssued ? listEmailDeliveries(entityId, "invoice", id) : Promise.resolve([]),
  ]);
  const email =
    isIssued && canManageLink ? { configured: emailDeliveryEnabled(), defaultEmail } : undefined;

  return (
    <>
      <InvoiceDetailScreen
        invoiceId={id}
        doc={doc}
        logo={logo}
        layout={layout}
        backHref={backHref}
        taxPanel={
          taxPreview ? (
            <TaxPreviewPanel
              preview={taxPreview}
              currency={doc.currency}
              sourceType="invoice"
              sourceId={id}
              canOverride={can(access, entityId, "tax.override")}
              next={selfHref}
            />
          ) : null
        }
        canEdit={can(access, entityId, "invoices.edit")}
        payment={
          canRecordPayment
            ? {
                accounts: accounts
                  .filter((a) => a.is_active)
                  .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` })),
                today: todayInBusinessZone(),
              }
            : undefined
        }
        permissions={{
          canIssue: can(access, entityId, "invoices.issue"),
          canVoid: can(access, entityId, "invoices.void"),
          canCorrect:
            can(access, entityId, "invoices.void") && can(access, entityId, "invoices.create"),
          canManageLink,
          canCancelDraft: can(access, entityId, "invoices.edit"),
        }}
        email={email}
        claimsNotice={
          claims.length > 0 ? (
            <section className="dashboard-section">
              <div className="dashboard-section-header">
                <h2 className="dashboard-section-title">Klaim Pembayaran Menunggu Konfirmasi</h2>
              </div>
              {claims.map((claim) => (
                <p key={claim.id} className="notice">
                  {claim.payer_name ?? "Pelanggan"} mengaku sudah membayar{" "}
                  {formatMoney(claim.amount, claim.currency)} ({formatShortDate(claim.payment_date)}
                  ). Invoice berubah menjadi lunas setelah klaim ini dikonfirmasi.
                </p>
              ))}
              {can(access, entityId, "invoices.confirm_payment") ? (
                <p>
                  <Link href={claimsHref} className="btn-secondary">
                    Buka Klaim Pembayaran
                  </Link>
                </p>
              ) : null}
            </section>
          ) : null
        }
      />
      <div className="record-detail">
        {doc.status === "issued" ? (
          <EmailHistory
            rows={emailRows}
            emptyText="Invoice ini belum pernah dikirim lewat email."
          />
        ) : null}
        <AttachmentsSection
          entityId={membership.entity_id}
          entity={entity}
          targetType="invoice"
          targetId={id}
          returnPath={`/sales/invoices/${id}`}
          canUpload={can(access, membership.entity_id, "documents.upload")}
          defaultPurpose="other"
        />
      </div>
    </>
  );
}
