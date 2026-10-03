import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getImportBatchRows, listImportBatches } from "@/services/imports/imports";
import { parseImportRowStatusFilter } from "@/domain/imports/imports";
import { ImportBatchDetailScreen } from "@/features/imports/ImportBatchDetailScreen";

/** Import batch Detail (unbuilt-screens backlog, decision 241). No single-batch read RPC exists, so the
 * header row is looked up from the active Entity's own `list_import_batches` result by id -- the same "look
 * up from the list result" shape Accounting Periods and Payments Made Detail already established, which
 * also guarantees a batch from another Entity is never shown under this one. Rows come from
 * `get_import_batch_rows`, with `?status=` passed through as its own `p_status`. */
export default async function ImportBatchDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string; status?: string }>;
}) {
  const { id } = await params;
  const { entity, status } = await searchParams;
  const { membership } = await requirePermission("system.import", { entityCode: entity });

  const batches = await listImportBatches({ entity_id: membership.entity_id });
  const batch = batches.find((candidate) => candidate.batch_id === id);
  if (!batch) notFound();

  const activeStatus = parseImportRowStatusFilter(status);
  const rows = await getImportBatchRows({ batch_id: batch.batch_id, status: activeStatus });
  const validRows =
    activeStatus === "valid"
      ? rows.length
      : activeStatus === undefined
        ? rows.filter((row) => row.status === "valid").length
        : (await getImportBatchRows({ batch_id: batch.batch_id, status: "valid" })).length;

  const backHref = entity
    ? `/admin/imports?entity=${encodeURIComponent(entity)}`
    : "/admin/imports";

  return (
    <ImportBatchDetailScreen
      batch={batch}
      rows={rows}
      activeStatus={activeStatus}
      entity={entity}
      backHref={backHref}
      validRows={validRows}
    />
  );
}
