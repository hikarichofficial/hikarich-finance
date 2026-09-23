import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import {
  rebuildSearchIndexInputSchema,
  refreshSearchIndexBatchInputSchema,
  searchInputSchema,
  searchResultListSchema,
  type SearchResultRow,
} from "@/schemas/search";

/**
 * Thin, typed wrappers over the Global Search RPCs (P11, Step 01 #34, Step 13 §17, Step 06 §11,
 * Step 08 §22). Every call runs as the signed-in person; the database filters an inaccessible record out
 * of the result set itself, before ranking (`app_authz.has_permission(entity, row.permission_key)`) —
 * never merely hiding it client-side. This layer validates the input shape, maps the database's error
 * prefixes to AuthzError without leaking detail, and validates what comes back. It holds no rule of its
 * own. Labels live in `@/domain/search`.
 */

async function callRpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code);
    throw new Error("Operasi pencarian gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons pencarian tidak dikenali.");
  return parsed.data;
}

const integerResultSchema = z.number().int();

export async function search(input: z.input<typeof searchInputSchema>): Promise<SearchResultRow[]> {
  const v = searchInputSchema.parse(input);
  return callRpc(
    "search",
    { p_entity: v.entity_id, p_query: v.query, p_limit: v.limit ?? 20 },
    searchResultListSchema,
  );
}

/** Manual "refresh now" (`system.import`). The scheduled path calls the same database function with the
 * service key and no signed-in user — this wrapper is for the manual action only. */
export async function refreshSearchIndexBatch(
  input: z.input<typeof refreshSearchIndexBatchInputSchema> = {},
): Promise<number> {
  const v = refreshSearchIndexBatchInputSchema.parse(input);
  return callRpc("refresh_search_index_batch", { p_limit: v.limit ?? 200 }, integerResultSchema);
}

/** Full, derived rebuild for one Entity (Step 08 §22). Not needed in normal operation — the outbox
 * trigger keeps the index current — but available as the recovery path. */
export async function rebuildSearchIndex(
  input: z.input<typeof rebuildSearchIndexInputSchema>,
): Promise<number> {
  const v = rebuildSearchIndexInputSchema.parse(input);
  return callRpc("rebuild_search_index", { p_entity: v.entity_id }, integerResultSchema);
}
