import "server-only";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { getServerEnv } from "@/lib/env";
import { getSupabasePublicConfig } from "./config";

/**
 * Service-role client for the Telegram bot (decision 422) and for nothing else. A webhook has no signed-in person,
 * so the bot calls the `telegram_*` database functions, which only the service role may execute. Each of those
 * functions acts as the one user who paired the bot (transaction-local claims), re-checks that user's permissions and
 * calls the ordinary expense functions, so every database guard still runs. This client never reads or writes a table
 * directly and never reaches the browser. Returns `null` when the key is not configured, so the routes can answer
 * "bot not configured" instead of failing.
 */
export function createTelegramBotClient(): SupabaseClient | null {
  const key = getServerEnv().SUPABASE_SERVICE_ROLE_KEY;
  if (!key) return null;
  const { url } = getSupabasePublicConfig();
  return createClient(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
