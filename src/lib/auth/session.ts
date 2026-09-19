import "server-only";
import { cache } from "react";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { accessSnapshotSchema, type AccessSnapshot } from "@/schemas/access";
import { parseAuthzCode } from "@/domain/authz/errors";
import type { SessionClaims } from "@/domain/authz/stepUp";

/** Verified JWT claims of the current request, or null when signed out. */
export const getSessionClaims = cache(async (): Promise<SessionClaims | null> => {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.auth.getClaims();
  if (error || !data?.claims?.sub) return null;
  return data.claims as SessionClaims;
});

/**
 * The database's own answer to "who am I and what may I do" (`public.my_access()`), computed fresh on
 * every request: a disabled user or removed membership is refused on the very next request, never cached.
 */
export const getAccessSnapshot = cache(async (): Promise<AccessSnapshot | null> => {
  const claims = await getSessionClaims();
  if (!claims) return null;
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("my_access");
  if (error) {
    if (parseAuthzCode(error.message) === "UNAUTHENTICATED") return null;
    throw new Error("Gagal memuat hak akses.");
  }
  const parsed = accessSnapshotSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons hak akses tidak dikenali.");
  return parsed.data;
});
