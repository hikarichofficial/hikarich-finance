import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getBillDetail } from "@/services/purchases/purchases";
import { getMoneyControl } from "@/services/money/money";
import { previewDocumentTax } from "@/services/tax/tax";
import { TaxPreviewPanel } from "@/features/tax/TaxPreviewPanel";
import { BillDetailScreen } from "@/features/purchases/BillDetailScreen";

/** Bill Detail (P13 Part 3b, Step 09 §10, §12). Permission to act is read off the currently active Entity
 * (`?entity=`), the same per-page pattern every other screen uses (DECISIONS 158); the database still
 * re-checks every action against the bill's own actual Entity regardless of what is active here. The
 * permission-to-action mapping mirrors each RPC's own check exactly (`submit_bill`→`bills.submit`,
 * `recall_bill`/`update_bill_draft`→`bills.edit`, `reject_bill`/`approve_bill`→`bills.approve`,
 * `void_bill`→`bills.void`, `correct_bill`→`bills.void`+`bills.create`; `cancel_bill` accepts either
 * `bills.edit` or `bills.void` depending on the bill's own status, which `BillActions` already branches on). */
export default async function BillDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("bills.view", { entityCode: entity });

  const bill = await getBillDetail(id).catch(() => null);
  if (!bill) notFound();

  const entityId = membership.entity_id;
  const canPay =
    can(access, entityId, "bills.pay") &&
    bill.status === "approved" &&
    bill.outstanding !== null &&
    Number(bill.outstanding) > 0;
  const accounts = canPay ? await getMoneyControl(entityId).catch(() => []) : [];
  const backHref = entity
    ? `/purchases/bills?entity=${encodeURIComponent(entity)}`
    : "/purchases/bills";

  const taxPreview =
    bill.status === "draft" || bill.status === "submitted"
      ? await previewDocumentTax({ source_type: "bill", source_id: id }).catch(() => null)
      : null;
  const selfHref = entity
    ? `/purchases/bills/${id}?entity=${encodeURIComponent(entity)}`
    : `/purchases/bills/${id}`;

  return (
    <BillDetailScreen
      bill={bill}
      backHref={backHref}
      taxPanel={
        taxPreview ? (
          <TaxPreviewPanel
            preview={taxPreview}
            currency={bill.currency}
            sourceType="bill"
            sourceId={id}
            canOverride={can(access, entityId, "tax.override")}
            next={selfHref}
          />
        ) : null
      }
      payment={
        canPay
          ? {
              accounts: accounts
                .filter((a) => a.is_active)
                .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` })),
              today: new Date().toISOString().slice(0, 10),
            }
          : undefined
      }
      permissions={{
        canSubmit: can(access, entityId, "bills.submit"),
        canEdit: can(access, entityId, "bills.edit"),
        canApprove: can(access, entityId, "bills.approve"),
        canVoid: can(access, entityId, "bills.void"),
        canCorrect: can(access, entityId, "bills.void") && can(access, entityId, "bills.create"),
      }}
    />
  );
}
