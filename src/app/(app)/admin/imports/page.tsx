import { requirePermission } from "@/services/identity/access";
import { listImportBatches } from "@/services/imports/imports";
import { parseImportDomainFilter } from "@/domain/imports/imports";
import { ImportBatchesListScreen } from "@/features/imports/ImportBatchesListScreen";

/** Import history (unbuilt-screens backlog, decision 241). `list_import_batches` is itself gated on
 * `system.import`, matching this page's gate and `navigation.ts`'s own declared permission. The domain
 * filter is passed straight through as the RPC's own `p_domain`. */
export default async function ImportBatchesListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; domain?: string }>;
}) {
  const { entity, domain } = await searchParams;
  const { membership } = await requirePermission("system.import", { entityCode: entity });
  const activeDomain = parseImportDomainFilter(domain);

  const rows = await listImportBatches({ entity_id: membership.entity_id, domain: activeDomain });

  return <ImportBatchesListScreen rows={rows} activeDomain={activeDomain} entity={entity} />;
}
