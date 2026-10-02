import Link from "next/link";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import { JournalDraftForm } from "@/features/accounting/JournalDraftForm";

/** Jurnal Manual (Step 09 §14), gated `accounting.journal_create` -- the permission `create_journal_draft`
 * itself checks. Only active, non-group accounts are offered; accounts closed to manual posting appear only
 * for a person who may override protected accounts (`accounting.protected_manage`). */
export default async function NewJournalPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("accounting.journal_create", {
    entityCode: entity,
  });
  const canOverride = can(access, membership.entity_id, "accounting.protected_manage");
  const accounts = await listLedgerAccounts(membership.entity_id);
  const options = accounts
    .filter((a) => a.status === "active" && !a.is_group && (a.allows_manual_posting || canOverride))
    .map((a) => ({
      id: a.id,
      label: a.allows_manual_posting
        ? `${a.code} · ${a.name}`
        : `${a.code} · ${a.name} (dilindungi)`,
    }));
  const backHref = entity
    ? `/accounting/journal?entity=${encodeURIComponent(entity)}`
    : "/accounting/journal";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar jurnal</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Akuntansi</p>
          <h1>Jurnal Manual</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <JournalDraftForm
          accounts={options}
          entity={entity}
          today={new Date().toISOString().slice(0, 10)}
          canOverride={canOverride}
        />
      </section>
    </div>
  );
}
