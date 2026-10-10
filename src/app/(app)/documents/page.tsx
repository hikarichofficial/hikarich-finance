import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listDocuments, listManagedDocumentPurposes } from "@/services/documents/documents";
import { parseDocumentTargetTypeFilter } from "@/domain/documents/documents";
import { DocumentPurposeManager } from "@/features/documents/DocumentPurposeManager";
import { DocumentsListScreen } from "@/features/documents/DocumentsListScreen";

const PAGE_SIZE = 50;

/** Documents Center listing (P13 Part 4, sixth increment; Step 01 #35, Step 15 §15). `?target_type=` is one
 * of the catalogued kinds; an absent or unrecognized value shows every document, matching `list_documents`'s
 * own "no filter" meaning and every other List screen's null-filter convention (decision 194). `?offset=` is
 * clamped to a non-negative integer -- a malformed value falls back to the first page rather than erroring.
 * The attachment-type manager (decision 401) sits under the list for anyone who may attach a file, since
 * `documents.upload` is the right that adds, renames and retires a type; without it the section is absent
 * rather than shown-and-refused. */
export default async function DocumentsListPage({
  searchParams,
}: {
  searchParams: Promise<{
    entity?: string;
    target_type?: string;
    q?: string;
    offset?: string;
  }>;
}) {
  const { entity, target_type, q, offset: offsetParam } = await searchParams;
  const { access, membership } = await requirePermission("documents.view", { entityCode: entity });
  const targetType = parseDocumentTargetTypeFilter(target_type) ?? null;
  const query = q ?? "";
  const parsedOffset = Number(offsetParam);
  const offset = Number.isInteger(parsedOffset) && parsedOffset > 0 ? parsedOffset : 0;

  const canUpload = can(access, membership.entity_id, "documents.upload");
  const [rows, purposes] = await Promise.all([
    listDocuments({
      entity_id: membership.entity_id,
      target_type: targetType ?? undefined,
      q: query || undefined,
      limit: PAGE_SIZE,
      offset,
    }),
    canUpload ? listManagedDocumentPurposes(membership.entity_id).catch(() => []) : [],
  ]);
  const returnPath = entity ? `/documents?entity=${encodeURIComponent(entity)}` : "/documents";

  return (
    <>
      <DocumentsListScreen
        rows={rows}
        activeFilter={targetType}
        query={query}
        entity={entity}
        offset={offset}
      />
      {canUpload ? <DocumentPurposeManager purposes={purposes} returnPath={returnPath} /> : null}
    </>
  );
}
