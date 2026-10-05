import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { getMoneyControl } from "@/services/money/money";
import { EquityActionsPanel } from "@/features/financing/FinancingForms";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getEquityEvent } from "@/services/financing/financing";
import { EquityDetailScreen } from "@/features/financing/EquityDetailScreen";
import { todayInBusinessZone } from "@/lib/time";

/** Capital & Equity Detail (P13 Part 3f, fourth increment, Step 09 §10, §16). */
export default async function EquityDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("equity.view", { entityCode: entity });

  const detail = await getEquityEvent(id).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `/assets/equity${qs}`;
  const canManage = can(access, membership.entity_id, "equity.manage");
  const accounts = canManage
    ? (await getMoneyControl(membership.entity_id).catch(() => []))
        .filter((a) => a.is_active)
        .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))
    : [];
  const today = todayInBusinessZone();
  // `equity_confirm` / `equity_reverse` also need `equity.approve` for a capital return or a dividend.
  const needsApproval = detail.kind === "capital_return" || detail.kind === "dividend";
  const canConfirmOrReverse = !needsApproval || can(access, membership.entity_id, "equity.approve");
  const activePayments = detail.payments
    .filter((p) => p.status === "active")
    .map((p) => ({
      id: p.id,
      label: `${p.number} · ${p.date} · ${formatMoney(p.amount, currency)}`,
    }));

  return (
    <EquityDetailScreen
      detail={detail}
      currency={currency}
      backHref={backHref}
      qs={qs}
      actionsPanel={
        canManage && (detail.status === "draft" || detail.status === "confirmed") ? (
          <EquityActionsPanel
            eventId={detail.id}
            status={detail.status}
            isDividend={detail.kind === "dividend"}
            needsApproval={needsApproval}
            canConfirmOrReverse={canConfirmOrReverse}
            outstanding={detail.outstanding}
            payments={activePayments}
            accounts={accounts}
            today={today}
            next={`/assets/equity/${detail.id}${qs}`}
          />
        ) : undefined
      }
    />
  );
}
