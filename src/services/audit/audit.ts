import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AUDIT_PAGE_SIZE, type AuditOperation } from "@/domain/audit/audit";
import { auditEventListSchema, profileNameListSchema, type AuditEventRow } from "@/schemas/audit";

/**
 * Audit Log reads (decision 242). No RPC lists audit events, so this reads `public.audit_events` directly
 * under its own `audit_events_select` RLS policy (`audit.view` on the row's Entity) -- the same
 * direct-table-read precedent decisions 161/167/170-173/239 established. The table is append-only
 * (update/delete/truncate are forbidden by trigger), so a page is stable once read.
 */

const AUDIT_EVENT_COLUMNS =
  "id, occurred_at, actor_type, actor_id, action, target_table, target_id, before_state, after_state, reason";

export interface AuditEventPage {
  rows: AuditEventRow[];
  hasMore: boolean;
}

/** One page of the Entity's audit events, newest first. Fetches one row beyond the page to know whether a
 * next page exists, since a count would need a second, more expensive query. */
export async function listAuditEvents(input: {
  entityId: string;
  operation: AuditOperation | undefined;
  offset: number;
}): Promise<AuditEventPage> {
  const supabase = await createSupabaseServerClient();
  let query = supabase
    .from("audit_events")
    .select(AUDIT_EVENT_COLUMNS)
    .eq("entity_id", input.entityId)
    .order("occurred_at", { ascending: false })
    .order("id", { ascending: false })
    .range(input.offset, input.offset + AUDIT_PAGE_SIZE);
  if (input.operation) query = query.like("action", `%.${input.operation}`);

  const { data, error } = await query;
  if (error) throw new Error("Gagal memuat log audit.");
  const parsed = auditEventListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons log audit tidak dikenali.");
  return {
    rows: parsed.data.slice(0, AUDIT_PAGE_SIZE),
    hasMore: parsed.data.length > AUDIT_PAGE_SIZE,
  };
}

/** Display names for the given profile ids, limited by `profiles_select` RLS (own profile, or users of a
 * shared Entity for `users.view` holders). An id the viewer may not read is simply absent from the map. */
export async function getProfileNames(ids: readonly string[]): Promise<Map<string, string>> {
  const unique = [...new Set(ids)];
  if (unique.length === 0) return new Map();
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("profiles")
    .select("id, display_name")
    .in("id", unique);
  if (error) throw new Error("Gagal memuat nama pengguna.");
  const parsed = profileNameListSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons nama pengguna tidak dikenali.");
  return new Map(parsed.data.map((row) => [row.id, row.display_name]));
}
