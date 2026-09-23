import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl, getTransfer } from "@/services/money/money";
import { mergeTransferRows } from "@/domain/money/transferList";
import { TransferDetailScreen } from "@/features/money/TransferDetailScreen";

/** Transfer Detail (P13 Part 3c, Step 09 §10, §13). Permission to act is read off the currently active Entity
 * (`?entity=`), the same per-page pattern every other screen uses (DECISIONS 158); the database still
 * re-checks every action against the transfer's own actual Entity regardless of what is active here. The
 * permission-to-action mapping mirrors each RPC's own check exactly (`confirm_transfer`/`reverse_transfer`
 * -> `money.transfer_approve`, `cancel_transfer` -> `money.transfer_create`). */
export default async function TransferDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("money.view", { entityCode: entity });

  const transfer = await getTransfer(id).catch(() => null);
  if (!transfer) notFound();

  const accounts = await getMoneyControl(membership.entity_id);
  const [row] = mergeTransferRows([transfer], accounts);

  const entityId = membership.entity_id;
  const backHref = entity
    ? `/money/transfers?entity=${encodeURIComponent(entity)}`
    : "/money/transfers";

  return (
    <TransferDetailScreen
      transfer={row}
      backHref={backHref}
      permissions={{
        canConfirm: can(access, entityId, "money.transfer_approve"),
        canCancel: can(access, entityId, "money.transfer_create"),
        canReverse: can(access, entityId, "money.transfer_approve"),
      }}
    />
  );
}
