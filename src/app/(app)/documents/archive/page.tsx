import { requirePermission } from "@/services/identity/access";
import { listDocumentArchive } from "@/services/documents/documents";
import { DocumentArchiveScreen } from "@/features/documents/DocumentArchiveScreen";

const PAGE_SIZE = 50;

/** Documents Archive (Step 09 §20, decision 252). Gated `documents.view`, which `list_document_archive`
 * checks; each document is shown only through a former target the caller may view. */
export default async function DocumentArchivePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; q?: string; offset?: string }>;
}) {
  const { entity, q, offset: offsetParam } = await searchParams;
  const { membership } = await requirePermission("documents.view", { entityCode: entity });
  const query = q ?? "";
  const parsed = Number(offsetParam);
  const offset = Number.isInteger(parsed) && parsed > 0 ? parsed : 0;

  const rows = await listDocumentArchive({
    entity_id: membership.entity_id,
    q: query,
    limit: PAGE_SIZE,
    offset,
  });

  return (
    <DocumentArchiveScreen
      rows={rows}
      query={query}
      entity={entity}
      offset={offset}
      hasMore={rows.length === PAGE_SIZE}
      pageSize={PAGE_SIZE}
    />
  );
}
