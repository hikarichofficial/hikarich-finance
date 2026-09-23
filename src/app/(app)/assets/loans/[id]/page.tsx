import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getLoan, getLoanSchedule } from "@/services/financing/financing";
import { LoanDetailScreen } from "@/features/financing/LoanDetailScreen";

/** Loan Detail (P13 Part 3f, second increment, Step 09 §10, §16). The active schedule is a separate RPC
 * (`loan_schedule`) from `loan_detail`, unlike Asset Detail where the schedule is embedded -- both are fetched
 * once the loan itself is confirmed to exist and be visible. */
export default async function LoanDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("loans.view", { entityCode: entity });

  const detail = await getLoan(id).catch(() => null);
  if (!detail) notFound();

  const [schedule, currency] = await Promise.all([
    getLoanSchedule({ loan_id: id }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const backHref = entity ? `/assets/loans?entity=${encodeURIComponent(entity)}` : "/assets/loans";

  return (
    <LoanDetailScreen
      detail={detail}
      schedule={schedule}
      currency={currency}
      entity={entity}
      backHref={backHref}
    />
  );
}
