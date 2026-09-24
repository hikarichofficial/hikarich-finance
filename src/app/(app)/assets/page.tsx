import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listAssets } from "@/services/assets/assets";
import { filterAssetRows, parseAssetStatusFilter } from "@/domain/assets/assetList";
import { AssetRegisterScreen } from "@/features/assets/AssetRegisterScreen";

/** Asset Register (P13 Part 3f, first increment, Step 09 §9, §16). `?status=` is sent straight to
 * `asset_register`'s own `p_status` argument (server-side filtering, unlike the Tax Ledger); `?q=` is a
 * client-side code/name search since no RPC parameter covers it. */
export default async function AssetRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { membership } = await requirePermission("assets.view", { entityCode: entity });
  const assetStatus = parseAssetStatusFilter(status) ?? null;
  const query = q ?? "";

  const [entries, currency] = await Promise.all([
    listAssets({ entity_id: membership.entity_id, status: assetStatus ?? undefined }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterAssetRows(entries, query);

  return (
    <AssetRegisterScreen
      rows={rows}
      status={assetStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
