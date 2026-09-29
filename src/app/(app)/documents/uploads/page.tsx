import { requirePermission } from "@/services/identity/access";
import { listDocuments } from "@/services/documents/documents";
import { filterDocumentsByLinkStatus } from "@/domain/documents/documents";
import { DocumentsListScreen } from "@/features/documents/DocumentsListScreen";

const PAGE_SIZE = 50;

/** Uploads (P13 Part 4, tenth increment; nav's own "Uploads" sub-route, `src/domain/shell/navigation.ts`,
 * DECISIONS 198). Documents Center already exposes every document's `link_count`; a raw upload nothing has
 * been linked to yet is `link_count === 0` (`filterDocumentsByLinkStatus`, `@/domain/documents/documents`)
 * -- the same distinction the label "Uploads" (as opposed to "Linked Evidence") already implies. No `target_
 * type` filter is ever sent to `list_documents`: an unlinked document has none of its own, so `list_documents`
 * only returns unlinked rows at all when `p_target_type` is null (`20260930100100_p11_documents.sql`) -- a
 * type filter here would always come back empty, so the tab row is hidden entirely (`showTargetTypeFilter=
 * false`) rather than offered and silently emptying the list. `hasMore` is computed from the raw fetched page
 * (before the link-status filter), so "Berikutnya" keeps reflecting `list_documents`'s own `p_offset`/`p_limit`
 * windowing even though the displayed row count is smaller. Upload itself (`registerDocument`/
 * `finalizeDocumentUpload`) stays deferred -- Storage is not yet configured (DECISIONS 142) -- so this route
 * only ever shows documents someone already registered by another path (an import, a future integration). */
export default async function DocumentUploadsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; q?: string; offset?: string }>;
}) {
  const { entity, q, offset: offsetParam } = await searchParams;
  const { membership } = await requirePermission("documents.view", { entityCode: entity });
  const query = q ?? "";
  const parsedOffset = Number(offsetParam);
  const offset = Number.isInteger(parsedOffset) && parsedOffset > 0 ? parsedOffset : 0;

  const page = await listDocuments({
    entity_id: membership.entity_id,
    q: query || undefined,
    limit: PAGE_SIZE,
    offset,
  });
  const rows = filterDocumentsByLinkStatus(page, "unlinked");

  return (
    <DocumentsListScreen
      rows={rows}
      activeFilter={null}
      query={query}
      entity={entity}
      offset={offset}
      basePath="/documents/uploads"
      title="Unggahan Belum Ditautkan"
      showTargetTypeFilter={false}
      hasMore={page.length === PAGE_SIZE}
    />
  );
}
