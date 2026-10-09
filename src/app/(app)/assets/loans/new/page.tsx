import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import { listPurposeSuggestions } from "@/services/financing/purposeSuggestions";
import { LoanCreateForm } from "@/features/financing/FinancingForms";
import { todayInBusinessZone } from "@/lib/time";
import { BackLink } from "@/features/shell/BackLink";

/** Tambah Pinjaman, gated `loans.manage` -- the permission `loan_create` itself checks. The loan is saved as a
 * draft; money moves only when it is activated on Loan Detail. */
export default async function NewLoanPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("loans.manage", { entityCode: entity });
  const backHref = entity ? `/assets/loans?entity=${encodeURIComponent(entity)}` : "/assets/loans";
  const knownParties = (await listContacts(membership.entity_id)).map((c) => c.display_name);
  const knownPurposes = await listPurposeSuggestions(membership.entity_id);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar pinjaman</BackLink>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pinjaman</p>
          <h1>Tambah Pinjaman</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <LoanCreateForm
          key={entity ?? membership.entity_code}
          entity={entity}
          isCompany={membership.entity_type === "company"}
          today={todayInBusinessZone()}
          knownParties={knownParties}
          knownPurposes={knownPurposes}
        />
      </section>
    </div>
  );
}
