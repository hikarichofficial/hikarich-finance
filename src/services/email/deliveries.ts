import "server-only";
import { z } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { uuidResultSchema } from "@/schemas/accounting";

/**
 * "Riwayat Pengiriman Email" (OWNER, 5 October 2026): every attempt to e-mail an invoice or a payment receipt is
 * written down (who got it, when, sent or failed) so the person can see what already went out and send it
 * again. Writing goes through `record_email_delivery` and is best effort: a failure to write the history must
 * never turn a delivered e-mail into an error. Reading is a direct RLS-governed select (`invoices.view`).
 */

export type EmailDeliveryKind = "invoice" | "payment_receipt";

export interface EmailDeliveryRow {
  id: string;
  recipient: string;
  status: "sent" | "failed";
  sent_at: string;
}

const rowSchema = z.object({
  id: z.string(),
  recipient: z.string(),
  status: z.enum(["sent", "failed"]),
  sent_at: z.string(),
});

export async function recordEmailDelivery(input: {
  entity_id: string;
  kind: EmailDeliveryKind;
  target_id: string;
  recipient: string;
  status: "sent" | "failed";
  detail?: string;
}): Promise<void> {
  try {
    const supabase = await createSupabaseServerClient();
    await supabase.rpc("record_email_delivery", {
      p_entity: uuidResultSchema.parse(input.entity_id),
      p_kind: input.kind,
      p_target: uuidResultSchema.parse(input.target_id),
      p_recipient: input.recipient,
      p_status: input.status,
      p_detail: input.detail ?? null,
    });
  } catch {
    // history is a convenience; the e-mail itself already went (or failed) on its own terms
  }
}

export async function listEmailDeliveries(
  entityId: string,
  kind: EmailDeliveryKind,
  targetId: string,
): Promise<EmailDeliveryRow[]> {
  try {
    const supabase = await createSupabaseServerClient();
    const { data } = await supabase
      .from("email_deliveries")
      .select("id, recipient, status, sent_at")
      .eq("entity_id", uuidResultSchema.parse(entityId))
      .eq("kind", kind)
      .eq("target_id", uuidResultSchema.parse(targetId))
      .order("sent_at", { ascending: false })
      .limit(50);
    return z.array(rowSchema).parse(data ?? []);
  } catch {
    return [];
  }
}
