import "server-only";
import { createSupabaseAnonClient } from "@/lib/supabase/anon";
import {
  publicClaimInputSchema,
  publicClaimResultSchema,
  publicInvoiceViewSchema,
  publicReceiptViewSchema,
  publicTokenSchema,
  type PublicInvoiceView,
  type PublicReceiptView,
} from "@/schemas/sales";
import { z } from "zod";

/**
 * The customer-facing token surface (P5, Step 11 §8-§11). It runs as the database's `anon` role, which can
 * execute exactly three functions and read no table. An unknown, revoked, expired, cancelled or malformed
 * token all give the same "unavailable" answer, so nothing can be probed; a malformed token never reaches the
 * database at all. A payment claim only records a PENDING request: it has no cash or accounting effect until a
 * person with authority confirms it (Step 07 §4).
 */

const UNAVAILABLE = { state: "unavailable" } as const;

export async function getPublicInvoice(token: string): Promise<PublicInvoiceView> {
  if (!publicTokenSchema.safeParse(token).success) return UNAVAILABLE;
  const supabase = createSupabaseAnonClient();
  const { data, error } = await supabase.rpc("public_invoice_view", { p_token: token });
  if (error) throw new Error("Faktur tidak dapat dimuat.");
  const parsed = publicInvoiceViewSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons faktur tidak dikenali.");
  return parsed.data;
}

export async function getPublicReceipt(
  token: string,
  receiptNumber: string,
): Promise<PublicReceiptView> {
  if (!publicTokenSchema.safeParse(token).success) return UNAVAILABLE;
  const number = z
    .string()
    .trim()
    .min(3)
    .max(60)
    .regex(/^[A-Za-z0-9/_.-]+$/)
    .safeParse(receiptNumber);
  if (!number.success) return UNAVAILABLE;
  const supabase = createSupabaseAnonClient();
  const { data, error } = await supabase.rpc("public_receipt_view", {
    p_token: token,
    p_receipt_number: number.data,
  });
  if (error) throw new Error("Kwitansi tidak dapat dimuat.");
  const parsed = publicReceiptViewSchema.safeParse(data);
  if (!parsed.success) throw new Error("Respons kwitansi tidak dikenali.");
  return parsed.data;
}

export type PublicClaimOutcome =
  | { state: "received"; alreadyReceived: boolean }
  | { state: "unavailable" }
  | { state: "throttled" }
  | { state: "conflict" }
  | { state: "invalid" };

/**
 * Records a pending claim. `requesterHash` is the salted hash of the requester built by the server route; the
 * database keeps it only for abuse limits.
 */
export async function submitPublicClaim(
  input: z.input<typeof publicClaimInputSchema>,
  requesterHash: string,
): Promise<PublicClaimOutcome> {
  const parsed = publicClaimInputSchema.safeParse(input);
  if (!parsed.success) {
    const tokenBad = parsed.error.issues.some((issue) => issue.path[0] === "token");
    return { state: tokenBad ? "unavailable" : "invalid" };
  }
  const v = parsed.data;
  const supabase = createSupabaseAnonClient();
  const { data, error } = await supabase.rpc("public_submit_payment_claim", {
    p_token: v.token,
    p_amount: v.amount,
    p_date: v.payment_date,
    p_payer_name: v.payer_name ?? null,
    p_reference: v.reference ?? null,
    p_note: v.note ?? null,
    p_client: requesterHash,
  });
  if (error) {
    const message = error.message ?? "";
    if (message.startsWith("UNAVAILABLE")) return { state: "unavailable" };
    if (message.startsWith("THROTTLED")) return { state: "throttled" };
    if (message.startsWith("CONFLICT")) return { state: "conflict" };
    if (message.startsWith("INVALID")) return { state: "invalid" };
    throw new Error("Konfirmasi pembayaran tidak dapat dikirim.");
  }
  const result = publicClaimResultSchema.safeParse(data);
  if (!result.success) throw new Error("Respons konfirmasi tidak dikenali.");
  return { state: "received", alreadyReceived: result.data.already_received };
}
