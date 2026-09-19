import { parsePublicEnv } from "@/lib/env";

/**
 * Browser-safe Supabase settings (URL + publishable key only). The service-role key is never read here:
 * P2 authorization runs entirely under the signed-in person's own JWT so RLS is always in force
 * (Step 13 (credentials/privileged operations); DECISIONS #27).
 */
export function getSupabasePublicConfig(): { url: string; publishableKey: string } {
  const env = parsePublicEnv({
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  });
  return {
    url: env.NEXT_PUBLIC_SUPABASE_URL,
    publishableKey: env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  };
}
