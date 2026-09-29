"use server";

import { search } from "@/services/search/search";
import type { SearchResultRow } from "@/schemas/search";

const SEARCH_RESULT_LIMIT = 8;

/**
 * Global Search action behind the Command Menu (P13 Part 6, Step 09 §6, Step 13 §17). A thin call-site
 * for the already-shipped `search()` service (P11) -- nothing about ranking, indexing or permission
 * filtering changes here, this only gives Command Menu (a client component) a plain async function it can
 * call as the person types, instead of a `<form>` submission.
 *
 * Any failure -- a too-short query caught by `searchInputSchema` mid-keystroke, a transient network error,
 * an unexpected `AuthzError` -- resolves to an empty list rather than surfacing an error state while the
 * person is still typing: Command Menu's existing "Tidak ada hasil" empty state already covers zero
 * results identically, whatever the reason.
 */
export async function searchRecordsAction(
  entityId: string,
  query: string,
): Promise<SearchResultRow[]> {
  const trimmed = query.trim();
  if (trimmed.length < 2) return [];
  try {
    return await search({ entity_id: entityId, query: trimmed, limit: SEARCH_RESULT_LIMIT });
  } catch {
    return [];
  }
}
