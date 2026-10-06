import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";
import { dedupeNames } from "@/domain/shared/typeahead";

/**
 * The purpose / description written on earlier loans, obligations and equity events of this Entity, newest first,
 * offered while typing "Tujuan" / "Keterangan" on the financing forms (OWNER, 6 October 2026). One list for all three
 * so the same wording is reused. Best effort: a failed read returns no suggestions, because a convenience must never
 * stop a form from opening.
 */
export async function listPurposeSuggestions(entityId: string): Promise<string[]> {
  try {
    const supabase = await createSupabaseServerClient();
    const entity = uuidResultSchema.parse(entityId);
    const read = async (table: "loans" | "other_obligations" | "equity_events") => {
      const { data } = await supabase
        .from(table)
        .select("purpose, created_at")
        .eq("entity_id", entity)
        .order("created_at", { ascending: false })
        .limit(300);
      return (data ?? []) as { purpose: string | null; created_at: string }[];
    };
    const rows = (
      await Promise.all([read("loans"), read("other_obligations"), read("equity_events")])
    )
      .flat()
      .sort((a, b) => b.created_at.localeCompare(a.created_at));
    return dedupeNames(rows.map((r) => r.purpose));
  } catch {
    return [];
  }
}
