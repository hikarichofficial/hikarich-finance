import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";

/**
 * The date a cancellation (reversal) is pre-filled with (OWNER, 13 October 2026). Cancelling a wrong entry
 * should put the books back as they were before it was recorded, so while the month of the original entry is
 * still open the reversal is dated that same day; otherwise (the month is closed) it is dated today. Reading
 * periods needs `accounting.view`: when the caller cannot read them, or the month has no period yet, the
 * original date is offered and the database still decides (it refuses a closed month with its own message).
 */
export async function defaultReversalDate(
  entityId: string,
  originalDate: string,
  today: string,
): Promise<string> {
  if (originalDate >= today) return today;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("accounting_periods")
    .select("status")
    .eq("entity_id", entityId)
    .lte("period_start", originalDate)
    .gte("period_end", originalDate)
    .limit(1)
    .maybeSingle();
  if (error || !data) return originalDate;
  return data.status === "open" ? originalDate : today;
}
