import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, getObligation } from "@/services/financing/financing";
import { ObligationDetailScreen } from "@/features/financing/ObligationDetailScreen";

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
  const { membership } = await requirePermission("loans.view", { entityCode: entity });

  const detail = await getObligation(id).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const backHref = `${LIST_HREF[detail.kind]}${qs}`;

  return <ObligationDetailScreen detail={detail} currency={currency} backHref={backHref} qs={qs} />;
}
