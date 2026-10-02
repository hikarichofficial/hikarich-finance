"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, authzErrorMessage } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { createContact } from "@/services/sales/sales";
import { recordContactFacts } from "@/services/tax/tax";

/**
 * Server actions behind Add Customer / Add Vendor and the contact's tax facts (decision 258). Both writes
 * are unmodified RPCs (`create_contact`, `tax_record_contact_facts`); this layer only shapes form input and
 * maps `AuthzError` to user-safe copy, adding the database's own reason when it gives one.
 */

export interface ContactActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export const idleContactActionState: ContactActionState = { status: "idle" };

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): ContactActionState {
  if (error instanceof AuthzError) {
    const match = /^(?:INVALID|CONFLICT):\s*([\s\S]+)$/.exec(error.message);
    const base = authzErrorMessage(error.code);
    return { status: "error", message: match?.[1] ? `${base} (${match[1].trim()})` : base };
  }
  return { status: "error", message: fallback };
}

export async function createContactAction(
  _previous: ContactActionState,
  formData: FormData,
): Promise<ContactActionState> {
  const entity = text(formData, "entity");
  const role = text(formData, "role") === "vendor" ? "vendor" : "customer";
  const basePath = role === "vendor" ? "/purchases/vendors" : "/sales/customers";
  let contactId: string;
  try {
    const { membership } = await requirePermission("contacts.create", { entityCode: entity });
    contactId = await createContact({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      kind: text(formData, "also_other_role") === "on" ? "both" : role,
      display_name: text(formData, "display_name"),
      legal_name: text(formData, "legal_name") || undefined,
      email: text(formData, "email") || undefined,
      phone: text(formData, "phone") || undefined,
      tax_identifier: text(formData, "tax_identifier") || undefined,
      address_line: text(formData, "address_line") || undefined,
      city: text(formData, "city") || undefined,
      country_code: text(formData, "country_code").toUpperCase() || undefined,
      notes: text(formData, "notes") || undefined,
      allow_similar_name: text(formData, "allow_similar_name") === "on",
    });
  } catch (error) {
    return errorState(
      error,
      "Kontak tidak dapat disimpan. Periksa nama, email, telepon dan kode negara.",
    );
  }
  revalidatePath(basePath);
  redirect(
    entity
      ? `${basePath}/${contactId}?entity=${encodeURIComponent(entity)}`
      : `${basePath}/${contactId}`,
  );
}

export async function recordContactFactsAction(
  _previous: ContactActionState,
  formData: FormData,
): Promise<ContactActionState> {
  try {
    await recordContactFacts({
      contact_id: text(formData, "contact_id"),
      idempotency_key: randomUUID(),
      effective_from: text(formData, "effective_from"),
      party_kind: text(formData, "party_kind") as never,
      residency: text(formData, "residency") as never,
      tax_id_status: text(formData, "tax_id_status") as never,
      pkp_status: text(formData, "pkp_status") as never,
      wht_exemption: text(formData, "wht_exemption") as never,
      evidence_note: text(formData, "evidence_note") || undefined,
    });
  } catch (error) {
    return errorState(error, "Data pajak kontak tidak dapat disimpan. Periksa isian.");
  }
  revalidatePath("/sales/customers");
  revalidatePath("/purchases/vendors");
  return { status: "ok", message: "Data pajak tersimpan." };
}
