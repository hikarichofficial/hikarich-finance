import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { getMoneyControl } from "@/services/money/money";
import { ObligationActionsPanel } from "@/features/financing/FinancingForms";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getObligation } from "@/services/financing/financing";
import { ObligationDetailScreen } from "@/features/financing/ObligationDetailScreen";
import { todayInBusinessZone } from "@/lib/time";

const LIST_HREF: Readonly<Record<"receivable" | "payable", string>> = {
  receivable: "/assets/other-receivables",
  payable: "/assets/other-payables",
};

/** Other Receivable/Payable Detail (P13 Part 3f, third increment, Step 09 §10, §16). One shared detail route for
 * both kinds (`obligation_detail` returns its own `kind`), rather than two separate `[id]` routes under each
 * list -- the same generic-detail choice a `kind` field naturally invites, unlike Loans/Assets which each have
 * only one kind of record. The back link is resolved from the obligation's own `kind` so it always returns to
 * the correct one of the two lists. */
export default async function ObligationDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("loans.view", { entityCode: entity });

  const detail = await getObligation(id).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `${LIST_HREF[detail.kind]}${qs}`;
  const canManage = can(access, membership.entity_id, "loans.manage");
  const accounts = canManage
    ? (await getMoneyControl(membership.entity_id).catch(() => []))
        .filter((a) => a.is_active)
        .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }))
    : [];
  const today = todayInBusinessZone();
  const activeSettlements = detail.settlements
    .filter((s) => s.status === "active")
    .map((s) => ({
      id: s.id,
      label: `${s.number} · ${s.date} · ${formatMoney(s.principal, currency)}`,
    }));
  const isOpen = detail.status === "open";

  return (
    <ObligationDetailScreen
      detail={detail}
      currency={currency}
      backHref={backHref}
      qs={qs}
      actionsPanel={
        canManage && detail.status !== "void" ? (
          <ObligationActionsPanel
            obligationId={detail.id}
            receivable={detail.kind === "receivable"}
            open={isOpen}
            canVoid={isOpen && detail.source_type === "manual" && activeSettlements.length === 0}
            outstanding={detail.outstanding}
            settlements={activeSettlements}
            accounts={accounts}
            today={today}
            next={`/assets/obligations/${detail.id}${qs}`}
          />
        ) : undefined
      }
    />
  );
}
