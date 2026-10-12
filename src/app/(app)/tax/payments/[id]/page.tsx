import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { listActiveFinancialAccounts } from "@/services/planning/planning";
import { getEntityBaseCurrency, listTaxEvidence, listTaxPayments } from "@/services/tax/tax";
import { TaxPaymentDetailScreen } from "@/features/tax/TaxPaymentDetailScreen";

/**
 * The page of one tax payment (decision 414), opened from the payment number in Riwayat Pembayaran on
 * "Pelaporan & Bukti". `tax_list_payments` has no single-item counterpart, so the row is looked up from the
 * Entity's own payments by id (the same shape as the Pembayaran Diterima page). Gated `tax.view` like the
 * list; reversing and uploading need `tax.mark_filed`, left to each action's own check.
 */
export default async function TaxPaymentDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const entityId = membership.entity_id;

  const [payments, currency, accounts] = await Promise.all([
    listTaxPayments({ entity_id: entityId, limit: 500 }),
    getEntityBaseCurrency(entityId),
    listActiveFinancialAccounts(entityId),
  ]);
  const payment = payments.find((candidate) => candidate.payment_id === id);
  if (!payment) notFound();

  const evidence = await listTaxEvidence({
    entity_id: entityId,
    target_type: "tax_payment",
    target_id: payment.payment_id,
  });

  const qs = new URLSearchParams({
    type: payment.tax_type,
    period: payment.tax_period.slice(0, 7),
  });
  if (entity) qs.set("entity", entity);

  return (
    <TaxPaymentDetailScreen
      payment={payment}
      currency={currency}
      entityId={entityId}
      entity={entity}
      accountName={accounts.find((a) => a.id === payment.financial_account_id)?.name ?? null}
      evidence={evidence}
      backHref={`/tax/filing?${qs.toString()}`}
    />
  );
}
