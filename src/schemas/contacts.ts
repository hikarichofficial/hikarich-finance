import { z } from "zod";
import { contactKindSchema } from "@/schemas/sales";

/**
 * Row contracts for the shared `contacts` table (Step 02 §4), read directly rather than through an RPC --
 * no `list_contacts`/`get_contact` function exists (only `create_contact`/`find_contact_duplicates` do), so
 * this extends the direct-table-read pattern already established for accounting/money (decisions
 * 161/167/169/170/171/172) to `public.contacts`. `tax_identifier` is a genuinely sensitive column (Step 06
 * §6): `contacts_select`'s own column-level grant (`app_private.expose_select`) never includes it for the
 * `authenticated` role, so it is never selected here at all -- selecting it would fail at the database
 * itself, not merely hide it in the UI. Revealing it (`reveal_sensitive('contact_tax_identifier', id)`,
 * gated on the separate `contacts.view_sensitive` permission) is deferred to a later increment, the same
 * "no ungrounded UI" discipline every other masked-field screen in this codebase already follows.
 */

export { contactKindSchema };
export const contactStatusSchema = z.enum(["active", "inactive"]);

export const contactRowSchema = z.object({
  id: z.uuid(),
  entity_id: z.uuid(),
  kind: contactKindSchema,
  display_name: z.string(),
  legal_name: z.string().nullable(),
  email: z.string().nullable(),
  phone: z.string().nullable(),
  address_line: z.string().nullable(),
  city: z.string().nullable(),
  country_code: z.string().nullable(),
  notes: z.string().nullable(),
  status: contactStatusSchema,
  created_at: z.string(),
  updated_at: z.string(),
});
export type ContactRow = z.infer<typeof contactRowSchema>;
export const contactRowsSchema = z.array(contactRowSchema);
