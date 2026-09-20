import "server-only";
import { createClient } from "@supabase/supabase-js";
import { getSupabasePublicConfig } from "./config";

/**
 * Stateless Supabase client for the public token surface (customer invoice page). It carries no cookies and no
 * session, so everything it does runs as the `anon` database role, which can execute exactly three functions
 * (`public_invoice_view`, `public_submit_payment_claim`, `public_receipt_view`) and read no table
 * (DECISIONS 70). It must never be given a person's session.
 */
export function createSupabaseAnonClient() {
  const { url, publishableKey } = getSupabasePublicConfig();
  return createClient(url, publishableKey, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
