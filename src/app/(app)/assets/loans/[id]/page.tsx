import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { getMoneyControl } from "@/services/money/money";
import { LoanActionsPanel } from "@/features/financing/FinancingForms";
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
  const { access, membership } = await requirePermission("loans.view", { entityCode: entity });

  const detail = await getLoan(id).catch(() => null);
  if (!detail) notFound();

  const [schedule, currency] = await Promise.all([
    getLoanSchedule({ loan_id: id }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const canManage = can(access, membership.entity_id, "loans.manage");
  const accounts = canManage
    ? (await getMoneyControl(membership.entity_id).catch(() => []))
        .filter((a) => a.is_active)
        .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))
    : [];
  const today = new Date().toISOString().slice(0, 10);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  // `loan_reverse_payment` refuses a payment of a superseded (restructured) schedule: offer the rest.
  const activeVersionId = detail.versions.find((v) => v.status === "active")?.id;
  const reversiblePayments = detail.payments
    .filter((p) => p.status === "active" && p.schedule_version_id === activeVersionId)
    .map((p) => ({
      id: p.id,
      label: `${p.number} · ${p.date} · ${formatMoney(p.principal, currency)} pokok`,
    }));
  const backHref = entity ? `/assets/loans?entity=${encodeURIComponent(entity)}` : "/assets/loans";

  return (
    <LoanDetailScreen
      detail={detail}
      schedule={schedule}
      currency={currency}
      entity={entity}
      backHref={backHref}
      actionsPanel={
        canManage && detail.status !== "cancelled" ? (
          <LoanActionsPanel
            loanId={detail.id}
            lent={detail.direction === "lent"}
            status={detail.status}
            outstanding={detail.outstanding}
            payments={reversiblePayments}
            accounts={accounts}
            today={today}
            next={`/assets/loans/${detail.id}${qs}`}
          />
        ) : undefined
      }
    />
  );
}
