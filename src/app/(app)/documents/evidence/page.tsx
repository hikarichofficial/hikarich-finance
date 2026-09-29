import { requirePermission } from "@/services/identity/access";
import { listDocuments } from "@/services/documents/documents";
import {
  filterDocumentsByLinkStatus,
  parseDocumentTargetTypeFilter,
} from "@/domain/documents/documents";
import { DocumentsListScreen } from "@/features/documents/DocumentsListScreen";

const PAGE_SIZE = 50;

/** Linked Evidence (P13 Part 4, tenth increment; nav's own "Linked Evidence" sub-route,
 * `src/domain/shell/navigation.ts`, DECISIONS 198). The mirror image of Uploads: a document with at least
 * one active link (`link_count > 0`, `filterDocumentsByLinkStatus`) has become evidence for a real record.
 * Unlike Uploads, a `target_type` filter is meaningful here (`list_documents` returns a linked document only
 * when its own type matches the filter), so the same tab row `/documents` already uses stays on, just
 * re-pointed at this route via `basePath`. `hasMore` is computed from the raw fetched page (before the
 * link-status filter), the same reasoning as Uploads, so pagination keeps reflecting `list_documents`'s own
 * windowing. */
export default async function DocumentEvidencePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; target_type?: string; q?: string; offset?: string }>;
}) {
  const { entity, target_type, q, offset: offsetParam } = await searchParams;
  const { membership } = await requirePermission("documents.view", { entityCode: entity });
  const targetType = parseDocumentTargetTypeFilter(target_type) ?? null;
  const query = q ?? "";
  const parsedOffset = Number(offsetParam);
  const offset = Number.isInteger(parsedOffset) && parsedOffset > 0 ? parsedOffset : 0;

  const page = await listDocuments({
    entity_id: membership.entity_id,
    target_type: targetType ?? undefined,
    q: query || undefined,
    limit: PAGE_SIZE,
    offset,
  });
  const rows = filterDocumentsByLinkStatus(page, "linked");

  return (
    <DocumentsListScreen
      rows={rows}
      activeFilter={targetType}
      query={query}
      entity={entity}
      offset={offset}
      basePath="/documents/evidence"
      title="Bukti Tertaut"
      hasMore={page.length === PAGE_SIZE}
    />
  );
}
