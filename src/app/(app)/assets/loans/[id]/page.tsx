import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { unpaidInstallments } from "@/domain/financing/financing";
import { getMoneyControl } from "@/services/money/money";
import { LoanActionsPanel } from "@/features/financing/FinancingForms";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getLoan, getLoanSchedule } from "@/services/financing/financing";
import { listAssets } from "@/services/assets/assets";
import { LoanDetailScreen } from "@/features/financing/LoanDetailScreen";
import { todayInBusinessZone } from "@/lib/time";

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
  // Instalments that were fully paid under an earlier version of the schedule (before a partial early repayment,
  // a rate change or a restructuring replaced it) are not in the current schedule: show them as history.
  const pastPaid = (
    await Promise.all(
      detail.versions
        .filter((v) => v.status === "superseded")
        .map((v) => getLoanSchedule({ loan_id: id, version_no: v.version_no }).catch(() => [])),
    )
  ).flatMap((rows) => rows.filter((row) => row.state === "paid"));
  const canManage = can(access, membership.entity_id, "loans.manage");
  const accounts = canManage
    ? (await getMoneyControl(membership.entity_id).catch(() => []))
        .filter((a) => a.is_active)
        .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))
    : [];
  // Only a borrowed loan can be linked to the fixed asset it financed (Step 01 #19, loan_set_asset's own guard).
  const assets =
    canManage && detail.direction === "borrowed"
      ? (await listAssets({ entity_id: membership.entity_id }).catch(() => []))
          .filter((a) => a.status !== "cancelled")
          .map((a) => ({ id: a.asset_id, label: `${a.asset_code} · ${a.name}` }))
      : [];
  const today = todayInBusinessZone();
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  // `loan_reverse_payment` refuses a payment of a superseded (restructured) schedule: offer the rest.
  const activeVersionId = detail.versions.find((v) => v.status === "active")?.id;
  const reversiblePayments = detail.payments
    .filter((p) => p.status === "active" && p.schedule_version_id === activeVersionId)
    .map((p) => ({
      id: p.id,
      label: `${p.number} · ${p.date} · ${formatMoney(p.principal, currency)} pokok`,
    }));
  // What is still owed on each instalment of the current schedule (decision 376): the form pays the next N of them.
  const activeVersion = detail.versions.find((v) => v.status === "active");
  const unpaid = unpaidInstallments(schedule, activeVersion?.version_no);
  const backHref = entity ? `/assets/loans?entity=${encodeURIComponent(entity)}` : "/assets/loans";
  // Only the most recent POSTED FX revaluation can be reversed (decision 281); `fx_revaluations` is already
  // newest-first.
  const fxLatestRevaluationId =
    detail.fx_revaluations.find((r) => r.status === "posted")?.id ?? null;

  return (
    <LoanDetailScreen
      detail={detail}
      schedule={schedule}
      pastPaid={pastPaid}
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
            fxCurrency={detail.fx_terms?.currency ?? null}
            fxNote={detail.fx_terms?.note ?? null}
            fxLatestRevaluationId={fxLatestRevaluationId}
            assets={assets}
            currentAssetId={detail.asset_id}
            unpaid={unpaid}
            currency={currency}
            canPrepay={activeVersion?.method !== "manual"}
          />
        ) : undefined
      }
    />
  );
}
