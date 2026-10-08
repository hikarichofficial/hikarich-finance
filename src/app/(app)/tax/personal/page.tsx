import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  getPersonalTaxSummary,
  getTaxGroupTurnover,
} from "@/services/tax/tax";
import { resolveTaxYear, runningTaxPeriod } from "@/domain/tax/tax";
import { GroupTurnoverCard } from "@/features/tax/GroupTurnoverCard";
import { computeInstallment, computePersonalTax } from "@/domain/tax/personalTax";
import { PersonalTaxScreen } from "@/features/tax/PersonalTaxScreen";

/** Pajak Pribadi (decision 365): the yearly PPh estimate of a Personal book. */
export default async function PersonalTaxPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; year?: string }>;
}) {
  const { entity, year } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const currentYear = Number(runningTaxPeriod().slice(0, 4));
  const shownYear = resolveTaxYear(year, currentYear);
  const summary = await getPersonalTaxSummary(membership.entity_id, shownYear);

  if (!summary) {
    // A company book: the personal tax does not apply, but the combined turnover is useful to see.
    const [group, currency] = await Promise.all([
      getTaxGroupTurnover(membership.entity_id, shownYear),
      getEntityBaseCurrency(membership.entity_id),
    ]);
    const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
    return (
      <div className="tax-page">
        <header className="tax-hero">
          <div>
            <p className="record-detail-eyebrow">Pajak</p>
            <h1>Pajak Pribadi</h1>
            <p className="record-detail-dates">
              Halaman ini untuk Buku Pribadi. Buka Buku Pribadi Anda lewat pemilih buku di kiri
              atas.
            </p>
          </div>
          <div className="tax-chips">
            <Link className="tax-chip" href={`/tax${qs}`}>
              <strong>Ringkasan Pajak</strong>
            </Link>
          </div>
        </header>
        {group ? <GroupTurnoverCard group={group} currency={currency} ownName="Buku ini" /> : null}
      </div>
    );
  }

  // The monthly PPh 25 instalment comes from last year's tax; a year already settled has none to pay.
  let installment = null;
  if (shownYear === currentYear) {
    const prior = await getPersonalTaxSummary(membership.entity_id, shownYear - 1).catch(
      () => null,
    );
    installment = computeInstallment(prior ? computePersonalTax(prior) : null, summary);
  }

  return (
    <PersonalTaxScreen
      summary={summary}
      entity={entity}
      currentYear={currentYear}
      installment={installment}
    />
  );
}
