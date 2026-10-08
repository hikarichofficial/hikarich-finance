import Link from "next/link";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { incomeTaxNote } from "@/domain/sales/income";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { getIncomeEntry, listIncomeCategories } from "@/services/sales/income";
import { ExpandableText } from "@/features/shared/ExpandableText";
import { AttachmentsSection } from "@/features/documents/AttachmentsSection";
import { ReverseIncomeForm } from "@/features/sales/IncomeForms";
import { formatShortDate } from "@/features/sales/format";
import { todayInBusinessZone } from "@/lib/time";

/** One income entry (decision 350), gated `invoices.view`. Cancelling needs `invoices.void`; documents follow
 * the usual `documents.upload` rule. */
export default async function IncomeDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const entry = await getIncomeEntry(entityId, id);
  if (!entry) notFound();

  const [categories, accounts, contacts] = await Promise.all([
    listIncomeCategories(entityId).catch(() => []),
    getMoneyControl(entityId).catch(() => []),
    listContacts(entityId).catch(() => []),
  ]);
  const category = categories.find((c) => c.id === entry.category_id);
  const account = accounts.find((a) => a.financial_account_id === entry.financial_account_id);
  const contact = contacts.find((c) => c.id === entry.contact_id);
  const backHref = entity ? `/sales/income?entity=${encodeURIComponent(entity)}` : "/sales/income";
  const reversed = entry.status === "reversed";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar pendapatan</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pendapatan</p>
          <h1>{category?.name ?? "Pendapatan"}</h1>
          <span className={`status-badge status-badge-${reversed ? "neutral" : "success"}`}>
            {reversed ? "Dibatalkan" : "Sudah tersimpan"}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <dl className="record-summary-grid">
          <div>
            <dt>Tanggal diterima</dt>
            <dd>{formatShortDate(entry.entry_date)}</dd>
          </div>
          <div>
            <dt>Jumlah</dt>
            <dd>{formatMoney(entry.amount, entry.currency)}</dd>
          </div>
          <div>
            <dt>Diterima di rekening</dt>
            <dd>{account ? `${account.name} (${account.currency})` : "—"}</dd>
          </div>
          <div>
            <dt>Dari siapa</dt>
            <dd>{contact?.display_name ?? "—"}</dd>
          </div>
          <div>
            <dt>Nomor bukti / referensi</dt>
            <dd>{entry.reference ?? "—"}</dd>
          </div>
          {entry.note ? (
            <div>
              <dt>Keterangan</dt>
              <dd>
                <ExpandableText text={entry.note} limit={80} />
              </dd>
            </div>
          ) : null}
          {reversed ? (
            <div>
              <dt>Dibatalkan</dt>
              <dd>
                {entry.reversed_date ? formatShortDate(entry.reversed_date) : ""} ·{" "}
                {entry.reverse_reason}
              </dd>
            </div>
          ) : null}
        </dl>
        <p className="hint">{incomeTaxNote(entry.in_turnover)}</p>
        {!reversed && can(access, entityId, "invoices.void") ? (
          <div className="record-actions">
            <ReverseIncomeForm entryId={entry.id} today={todayInBusinessZone()} />
          </div>
        ) : null}
      </section>

      <AttachmentsSection
        embedded
        entityId={entityId}
        entity={entity}
        targetType="income_entry"
        targetId={id}
        returnPath={`/sales/income/${id}`}
        canUpload={can(access, entityId, "documents.upload")}
        defaultPurpose="receipt"
      />
    </div>
  );
}
