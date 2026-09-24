import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getEquityEvent } from "@/services/financing/financing";
import { EquityDetailScreen } from "@/features/financing/EquityDetailScreen";

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
  const { membership } = await requirePermission("equity.view", { entityCode: entity });

  const detail = await getEquityEvent(id).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `/assets/equity${qs}`;

  return <EquityDetailScreen detail={detail} currency={currency} backHref={backHref} qs={qs} />;
}
