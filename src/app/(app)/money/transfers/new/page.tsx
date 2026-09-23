import Link from "next/link";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { TransferForm } from "@/features/money/TransferForm";

/** Transfer create form (P13 Part 3c, Step 09 §13). Gated on `money.transfer_create`, the exact permission
 * `create_transfer` itself checks (decision 162's precedent); every role template that grants
 * `money.transfer_create` also grants `money.view` (confirmed in `20260920100100_p2_permission_catalog.sql`),
 * so fetching the account list below never hits a permission this page didn't already require. */
export default async function NewTransferPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("money.transfer_create", {
    entityCode: entity,
  });
  const accounts = await getMoneyControl(membership.entity_id);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link
          href={
            entity ? `/money/transfers?entity=${encodeURIComponent(entity)}` : "/money/transfers"
          }
        >
          ← Kembali ke daftar transfer
        </Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Transfer Antar Akun</p>
          <h1>Buat Transfer Baru</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <TransferForm
          accounts={accounts}
          entityId={membership.entity_id}
          entity={entity}
          canConfirmOnCreate={can(access, membership.entity_id, "money.transfer_approve")}
        />
      </section>
    </div>
  );
}
