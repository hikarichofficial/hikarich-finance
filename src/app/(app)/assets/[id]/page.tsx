import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getAsset, getEntityBaseCurrency } from "@/services/assets/assets";
import { AssetDetailScreen } from "@/features/assets/AssetDetailScreen";

/** Asset Detail (P13 Part 3f, first increment, Step 09 §10, §16). */
export default async function AssetDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { membership } = await requirePermission("assets.view", { entityCode: entity });

  const detail = await getAsset({ asset_id: id }).catch(() => null);
  if (!detail) notFound();

  const currency = await getEntityBaseCurrency(membership.entity_id);
  const backHref = entity ? `/assets?entity=${encodeURIComponent(entity)}` : "/assets";

  return (
    <AssetDetailScreen detail={detail} currency={currency} entity={entity} backHref={backHref} />
  );
}
