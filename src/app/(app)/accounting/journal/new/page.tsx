import Link from "next/link";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  listJournalDescriptionSuggestions,
  listJournalLineDescriptionSuggestions,
  listLedgerAccounts,
} from "@/services/accounting/ledger";
import { accountClassLabel } from "@/domain/accounting/coaList";
import { JournalDraftForm } from "@/features/accounting/JournalDraftForm";
import { todayInBusinessZone } from "@/lib/time";

/** Order of the account groups in the picker: what a person records most often (income, costs) first, the
 * system-protected accounts last. */
const GROUP_ORDER = ["Pendapatan", "Beban", "Aset", "Liabilitas", "Ekuitas", "Lainnya"] as const;
const PROTECTED_GROUP = "Akun sistem (dilindungi, hindari)";

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
  const [accounts, descriptionSuggestions, lineDescriptionSuggestions] = await Promise.all([
    listLedgerAccounts(membership.entity_id),
    listJournalDescriptionSuggestions(membership.entity_id),
    listJournalLineDescriptionSuggestions(membership.entity_id),
  ]);
  const groupOf = (a: (typeof accounts)[number]): string => {
    if (!a.allows_manual_posting) return PROTECTED_GROUP;
    const label = accountClassLabel(a.account_class);
    return (GROUP_ORDER as readonly string[]).includes(label) ? label : "Lainnya";
  };
  const rank = (group: string): number =>
    group === PROTECTED_GROUP
      ? GROUP_ORDER.length
      : (GROUP_ORDER as readonly string[]).indexOf(group);
  const options = accounts
    .filter((a) => a.status === "active" && !a.is_group && (a.allows_manual_posting || canOverride))
    .map((a) => ({
      id: a.id,
      label: `${a.code} · ${a.name}`,
      group: groupOf(a),
      code: a.code,
      isIncome: a.account_class === "revenue" || a.account_class === "other_income",
    }))
    .sort((x, y) => rank(x.group) - rank(y.group) || x.code.localeCompare(y.code))
    .map(({ id, label, group, isIncome }) => ({ id, label, group, isIncome }));
  const incomeHref =
    can(access, membership.entity_id, "invoices.issue") &&
    can(access, membership.entity_id, "invoices.confirm_payment")
      ? entity
        ? `/sales/income/new?entity=${encodeURIComponent(entity)}`
        : "/sales/income/new"
      : undefined;
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
          <p className="hint">
            Untuk pembukuan lanjutan. Pendapatan sehari-hari cukup dicatat lewat menu Invoice,
            Pembayaran Diterima, atau Catat Pendapatan (untuk yang tanpa invoice) di bagian
            Penjualan; pengeluaran lewat menu Beban di bagian Pembelian. Akun dikelompokkan menurut
            jenisnya; akun sistem ada di paling bawah.
          </p>
        </div>
      </header>
      <section className="dashboard-section">
        <JournalDraftForm
          accounts={options}
          entity={entity}
          today={todayInBusinessZone()}
          canOverride={canOverride}
          descriptionSuggestions={descriptionSuggestions}
          lineDescriptionSuggestions={lineDescriptionSuggestions}
          incomeHref={incomeHref}
        />
      </section>
    </div>
  );
}
