import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getServerEnv } from "@/lib/env";
import { getSupabasePublicConfig } from "./config";

/**
 * Service-role client, for Supabase Storage only (decision 275). It bypasses RLS, so it is never used for a
 * table read or write and never reaches the browser: `src/services/documents/storage.ts` is its only caller,
 * and every call there follows a permission check the database made under the person's own session.
 * Returns `null` when the key is not configured (Preview, local), so the caller can say that file storage
 * is not switched on instead of failing.
 */
export function createSupabaseAdminClient(): SupabaseClient | null {
  const key = getServerEnv().SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return null;
  const { url } = getSupabasePublicConfig();
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
