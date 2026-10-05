"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
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

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): ContactActionState {
  if (error instanceof AuthzError) {
    return { status: "error", message: describeAuthzError(error) };
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

export interface QuickCreateContactState {
  status: "idle" | "ok" | "error";
  message?: string;
  contact?: { id: string; display_name: string };
}

export const idleQuickCreateContactState: QuickCreateContactState = { status: "idle" };

/**
 * Quick-add a customer or vendor from inside another form (owner, 4 October 2026: "saat pembuatan invoice
 * menu isian pelanggan wajib ada tombol tambah pelanggan baru"), without leaving the page the person is
 * already filling in -- unlike `createContactAction` above, this never redirects, it hands the new
 * contact's id/name back so the caller can select it in place. Same `create_contact` RPC, same minimal
 * required field (display_name); the full Add Customer/Vendor screen still covers every other field for
 * when the person wants to fill in more up front.
 */
export async function quickCreateContactAction(
  role: "customer" | "vendor",
  _previous: QuickCreateContactState,
  formData: FormData,
): Promise<QuickCreateContactState> {
  const entity = text(formData, "entity");
  const displayName = text(formData, "display_name");
  const basePath = role === "vendor" ? "/purchases/vendors" : "/sales/customers";
  try {
    const { membership } = await requirePermission("contacts.create", { entityCode: entity });
    const contactId = await createContact({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      kind: role,
      display_name: displayName,
      email: text(formData, "email") || undefined,
      phone: text(formData, "phone") || undefined,
    });
    revalidatePath(basePath);
    return { status: "ok", contact: { id: contactId, display_name: displayName } };
  } catch (error) {
    if (error instanceof AuthzError) {
      return { status: "error", message: describeAuthzError(error) };
    }
    return {
      status: "error",
      message: `${role === "vendor" ? "Vendor" : "Pelanggan"} tidak dapat disimpan. Periksa nama, email dan telepon.`,
    };
  }
}

/** Bound for `useActionState`, which calls its action as `(previousState, formData)` -- Next's documented
 * way to pass an extra fixed argument to a Server Action. */
export const quickCreateCustomerAction = quickCreateContactAction.bind(null, "customer");
export const quickCreateVendorAction = quickCreateContactAction.bind(null, "vendor");

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
