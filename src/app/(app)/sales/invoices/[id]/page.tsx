import { AttachmentsSection } from "@/features/documents/AttachmentsSection";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getInvoiceDocument, getInvoiceOwner } from "@/services/sales/sales";
import { getEntityLogo } from "@/services/settings/settings";
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
  const accounts = canRecordPayment ? await getMoneyControl(entityId).catch(() => []) : [];
  const backHref = entity
    ? `/sales/invoices?entity=${encodeURIComponent(entity)}`
    : "/sales/invoices";

  const taxPreview =
    doc.status === "draft"
      ? await previewDocumentTax({ source_type: "invoice", source_id: id }).catch(() => null)
      : null;
  const selfHref = entity
    ? `/sales/invoices/${id}?entity=${encodeURIComponent(entity)}`
    : `/sales/invoices/${id}`;

  const canManageLink = can(access, entityId, "invoices.regenerate_link");
  const email =
    doc.status === "issued" && canManageLink
      ? {
          configured: emailDeliveryEnabled(),
          defaultEmail: await getInvoiceOwner(id)
            .then((owner) => (owner ? getContact(owner.customer_id) : null))
            .then((contact) => contact?.email ?? null)
            .catch(() => null),
        }
      : undefined;

  return (
    <>
      <InvoiceDetailScreen
        invoiceId={id}
        doc={doc}
        logo={await getEntityLogo(entityId)}
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
      />
      <div className="record-detail">
        {doc.status === "issued" ? (
          <EmailHistory
            rows={await listEmailDeliveries(membership.entity_id, "invoice", id)}
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
