import "server-only";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";
import { contactRowSchema, contactRowsSchema, type ContactRow } from "@/schemas/contacts";

/**
 * Direct reads over `public.contacts` (P13 Part 3, Sales/Purchases: Customers, Vendors). No RPC lists or
 * reads a contact -- only `create_contact`/`find_contact_duplicates` exist -- so this is a plain
 * `.from("contacts").select(...)` covered by `contacts_select`'s own `contacts.view`-gated RLS policy,
 * exactly the shape `src/services/accounting/ledger.ts` established for journals/ledger accounts/periods.
 * `tax_identifier` is never selected (see `schemas/contacts.ts`'s own doc comment).
 */

const CONTACT_COLUMNS =
  "id, entity_id, kind, display_name, legal_name, email, phone, address_line, city, country_code, notes, status, created_at, updated_at";

export async function listContacts(entityId: string): Promise<ContactRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("contacts")
    .select(CONTACT_COLUMNS)
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .order("display_name", { ascending: true });
  if (error) throw new Error("Gagal memuat daftar kontak.");
  const parsed = contactRowsSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons kontak tidak dikenali.");
  return parsed.data;
}

/** `null` for a missing or inaccessible contact -- the same answer either way (no existence leak), matching
 * every other direct-read `get*` in this codebase. */
export async function getContact(contactId: string): Promise<ContactRow | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("contacts")
    .select(CONTACT_COLUMNS)
    .eq("id", uuidResultSchema.parse(contactId))
    .maybeSingle();
  if (error) throw new Error("Gagal memuat kontak.");
  if (!data) return null;
  const parsed = contactRowSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons kontak tidak dikenali.");
  return parsed.data;
}

/** The tax facts of a contact now in force (latest effective date, not superseded), or `null` when none is
 * recorded or the caller lacks `tax.view` (RLS answers both the same way). Decision 258. */
export async function getContactTaxFacts(contactId: string): Promise<{
  effective_from: string;
  party_kind: string;
  residency: string;
  tax_id_status: string;
  pkp_status: string;
  wht_exemption: string;
} | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("tax_contact_facts")
    .select("effective_from, party_kind, residency, tax_id_status, pkp_status, wht_exemption")
    .eq("contact_id", uuidResultSchema.parse(contactId))
    .is("superseded_at", null)
    .order("effective_from", { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error || !data) return null;
  return data as never;
}
