import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getInvoiceDocument } from "@/services/sales/sales";
import { getMoneyControl } from "@/services/money/money";
import { previewDocumentTax } from "@/services/tax/tax";
import { TaxPreviewPanel } from "@/features/tax/TaxPreviewPanel";
import { InvoiceDetailScreen } from "@/features/sales/InvoiceDetailScreen";

/** Invoice Detail (P13 Part 3a, Step 09 §10, §11). Permission to act is read off the currently active
 * Entity (`?entity=`), the same per-page pattern every other screen uses (DECISIONS 158); the database
 * still re-checks every action against the invoice's own actual Entity regardless of what is active here. */
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

  return (
    <InvoiceDetailScreen
      invoiceId={id}
      doc={doc}
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
              today: new Date().toISOString().slice(0, 10),
            }
          : undefined
      }
      permissions={{
        canIssue: can(access, entityId, "invoices.issue"),
        canVoid: can(access, entityId, "invoices.void"),
        canCorrect:
          can(access, entityId, "invoices.void") && can(access, entityId, "invoices.create"),
        canManageLink: can(access, entityId, "invoices.regenerate_link"),
      }}
    />
  );
}
