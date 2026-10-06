import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listPurposeSuggestions } from "@/services/financing/purposeSuggestions";
import { obligationKindTitle } from "@/domain/financing/obligationList";
import { ObligationCreateForm } from "@/features/financing/FinancingForms";
import { todayInBusinessZone } from "@/lib/time";

const LIST_HREF: Readonly<Record<"receivable" | "payable", string>> = {
  receivable: "/assets/other-receivables",
  payable: "/assets/other-payables",
};

/** Tambah Piutang Lain / Utang Lain (`?kind=receivable|payable`), gated `loans.manage` -- the permission
 * `obligation_create` itself checks. This form covers the cash origin only (money moved through a cash or
 * bank account); the non-cash "offset" origin needs a ledger-account choice and is not offered here. */
export default async function NewObligationPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; kind?: string }>;
}) {
  const { entity, kind: rawKind } = await searchParams;
  const { membership } = await requirePermission("loans.manage", { entityCode: entity });
  const kind = rawKind === "payable" ? "payable" : "receivable";
  const title = obligationKindTitle(kind);
  const backHref = entity
    ? `${LIST_HREF[kind]}?entity=${encodeURIComponent(entity)}`
    : LIST_HREF[kind];
  const accounts = (await getMoneyControl(membership.entity_id).catch(() => []))
    .filter((a) => a.is_active)
    .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }));
  const knownParties = (await listContacts(membership.entity_id)).map((c) => c.display_name);
  const knownPurposes = await listPurposeSuggestions(membership.entity_id);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar {title.toLowerCase()}</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{title}</p>
          <h1>Tambah {title}</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ObligationCreateForm
          key={entity ?? membership.entity_code}
          entity={entity}
          kind={kind}
          accounts={accounts}
          today={todayInBusinessZone()}
          knownParties={knownParties}
          knownPurposes={knownPurposes}
        />
      </section>
    </div>
  );
}
