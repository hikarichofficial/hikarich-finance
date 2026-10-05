import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listContacts } from "@/services/contacts/contacts";
import { EQUITY_KIND_LABELS } from "@/domain/financing/financing";
import { EquityCreateForm } from "@/features/financing/FinancingForms";
import { todayInBusinessZone } from "@/lib/time";

const COMPANY_KINDS = ["contribution", "capital_return", "dividend"] as const;
const PERSONAL_KINDS = [
  "investment_contribution",
  "investment_return",
  "distribution_received",
] as const;

/** Tambah Modal / Ekuitas, gated `equity.manage` -- the permission `equity_create` itself checks. The kinds
 * offered follow the same rule `equity_create` enforces: a company records contributions, capital returns
 * and dividends; any other Entity records investment contributions, returns and distributions received. */
export default async function NewEquityEventPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("equity.manage", { entityCode: entity });
  const backHref = entity
    ? `/assets/equity?entity=${encodeURIComponent(entity)}`
    : "/assets/equity";
  const kindIds: readonly (keyof typeof EQUITY_KIND_LABELS)[] =
    membership.entity_type === "company" ? COMPANY_KINDS : PERSONAL_KINDS;
  const kinds = kindIds.map((kind) => ({ id: kind, label: EQUITY_KIND_LABELS[kind] }));
  const knownParties = (await listContacts(membership.entity_id)).map((c) => c.display_name);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke Modal & Ekuitas</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Modal & Ekuitas</p>
          <h1>Tambah Modal / Ekuitas</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <EquityCreateForm
          key={entity ?? membership.entity_code}
          entity={entity}
          kinds={kinds}
          today={todayInBusinessZone()}
          knownParties={knownParties}
        />
      </section>
    </div>
  );
}
