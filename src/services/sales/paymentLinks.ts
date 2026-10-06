import "server-only";
import { z } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { uuidResultSchema } from "@/schemas/accounting";

/**
 * The "Tautan Pembayaran" master (decision 307): named https addresses of a payment gateway page, kept in
 * `payment_channels` with kind `payment_link`. An invoice picks one; the customer opens it from the invoice.
 * The link only leads the customer to the gateway: the payment is still recorded by hand afterwards.
 */

export interface PaymentLinkRow {
  id: string;
  name: string;
  payment_url: string;
  is_active: boolean;
}

const nameSchema = z.string().trim().min(2).max(120);
const urlSchema = z
  .string()
  .trim()
  .max(500)
  .regex(/^https:\/\/\S+$/);

/** The Entity's payment links (RLS: `money.view`). A person who cannot read them simply sees none. */
export async function listPaymentLinks(entityId: string): Promise<PaymentLinkRow[]> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase
    .from("payment_channels")
    .select("id, name, payment_url, is_active")
    .eq("entity_id", uuidResultSchema.parse(entityId))
    .eq("method_kind", "payment_link")
    .order("name", { ascending: true });
  if (error) return [];
  return (data ?? []).filter(
    (row): row is PaymentLinkRow =>
      typeof (row as { payment_url?: unknown }).payment_url === "string",
  );
}

function fail(error: { message: string }, fallback: string): never {
  const code = parseAuthzCode(error.message);
  if (code) throw new AuthzError(code, error.message);
  throw new Error(fallback);
}

export async function createPaymentLink(input: {
  entity_id: string;
  idempotency_key: string;
  name: string;
  url: string;
}): Promise<string> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc("create_payment_link", {
    p_entity: uuidResultSchema.parse(input.entity_id),
    p_key: input.idempotency_key,
    p_name: nameSchema.parse(input.name),
    p_url: urlSchema.parse(input.url),
  });
  if (error) fail(error, "Tautan pembayaran tidak dapat disimpan.");
  return uuidResultSchema.parse(data);
}

export async function updatePaymentLink(input: {
  entity_id: string;
  id: string;
  name: string;
  url: string;
  active: boolean;
}): Promise<void> {
  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.rpc("update_payment_link", {
    p_entity: uuidResultSchema.parse(input.entity_id),
    p_id: uuidResultSchema.parse(input.id),
    p_name: nameSchema.parse(input.name),
    p_url: urlSchema.parse(input.url),
    p_active: input.active,
  });
  if (error) fail(error, "Tautan pembayaran tidak dapat diubah.");
}
