import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency } from "@/services/tax/tax";
import { AccountForm } from "@/features/money/AccountForm";

/** Add Account (Step 09 §13, decision 258), gated `money.edit` -- the permission
 * `create_financial_account` itself checks. */
export default async function NewAccountPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("money.edit", { entityCode: entity });
  const baseCurrency = await getEntityBaseCurrency(membership.entity_id);
  const backHref = entity
    ? `/money/accounts?entity=${encodeURIComponent(entity)}`
    : "/money/accounts";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar rekening</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Kas & Bank</p>
          <h1>Tambah Rekening</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <AccountForm entity={entity} baseCurrency={baseCurrency} />
      </section>
    </div>
  );
}
