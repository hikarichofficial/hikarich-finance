import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getBillDetail } from "@/services/purchases/purchases";
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
  const { access, membership } = await requirePermission("bills.view", {
    entityCode: entity,
  });

  const bill = await getBillDetail(id).catch(() => null);
  if (!bill) notFound();

  const entityId = membership.entity_id;
  const backHref = entity
    ? `/purchases/bills?entity=${encodeURIComponent(entity)}`
    : "/purchases/bills";

  return (
    <BillDetailScreen
      bill={bill}
      backHref={backHref}
      permissions={{
        canSubmit: can(access, entityId, "bills.submit"),
        canEdit: can(access, entityId, "bills.edit"),
        canApprove: can(access, entityId, "bills.approve"),
        canVoid: can(access, entityId, "bills.void"),
        canCorrect:
          can(access, entityId, "bills.void") &&
          can(access, entityId, "bills.create"),
      }}
    />
  );
}
