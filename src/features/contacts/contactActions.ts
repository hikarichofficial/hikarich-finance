"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { getContact, setContactStatus, updateContact } from "@/services/contacts/contacts";
import { createContact } from "@/services/sales/sales";
import { recordContactFacts } from "@/services/tax/tax";
import type { QuickCreateContactState } from "./contactActionsState";

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
  await setFlash("Kontak tersimpan.");
  redirect(
    entity
      ? `${basePath}/${contactId}?entity=${encodeURIComponent(entity)}`
      : `${basePath}/${contactId}`,
  );
}

/**
 * Quick-add a customer or vendor from inside another form (owner, 4 October 2026: "saat pembuatan invoice
 * menu isian pelanggan wajib ada tombol tambah pelanggan baru"), without leaving the page the person is
 * already filling in -- unlike `createContactAction` above, this never redirects, it hands the new
 * contact's id/name back so the caller can select it in place. Same `create_contact` RPC, same minimal
 * required field (display_name); the full Add Customer/Vendor screen still covers every other field for
 * when the person wants to fill in more up front.
 */
async function quickCreateContactAction(
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

/** One async function per role for `useActionState`, which calls its action as `(previousState, formData)`.
 * A "use server" file may export only async functions (never a constant or an object), so these are plain
 * wrappers rather than `.bind(...)` constants. */
export async function quickCreateCustomerAction(
  previous: QuickCreateContactState,
  formData: FormData,
): Promise<QuickCreateContactState> {
  return quickCreateContactAction("customer", previous, formData);
}

export async function quickCreateVendorAction(
  previous: QuickCreateContactState,
  formData: FormData,
): Promise<QuickCreateContactState> {
  return quickCreateContactAction("vendor", previous, formData);
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

const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

function basePathOf(kind: string | null): string {
  return kind === "vendor" ? "/purchases/vendors" : "/sales/customers";
}

/** Edit a customer's or vendor's details (finding #90). The contact must belong to the active Entity. */
export async function updateContactAction(
  _previous: ContactActionState,
  formData: FormData,
): Promise<ContactActionState> {
  const entity = text(formData, "entity");
  const contactId = text(formData, "contact_id");
  const role = text(formData, "role") === "vendor" ? "vendor" : "customer";
  const displayName = text(formData, "display_name");
  const email = text(formData, "email");
  const country = text(formData, "country_code").toUpperCase();
  if (displayName === "") return { status: "error", message: "Nama wajib diisi." };
  if (email !== "" && !EMAIL_PATTERN.test(email)) {
    return { status: "error", message: "Format email tidak valid." };
  }
  if (country !== "" && !/^[A-Z]{2}$/.test(country)) {
    return { status: "error", message: "Kode negara harus 2 huruf, mis. ID." };
  }
  const basePath = basePathOf(role);
  try {
    const { membership } = await requirePermission("contacts.edit", { entityCode: entity });
    const existing = await getContact(contactId);
    if (!existing || existing.entity_id !== membership.entity_id) {
      return { status: "error", message: "Kontak tidak ditemukan." };
    }
    await updateContact(contactId, {
      display_name: displayName,
      legal_name: text(formData, "legal_name") || null,
      email: email || null,
      phone: text(formData, "phone") || null,
      address_line: text(formData, "address_line") || null,
      city: text(formData, "city") || null,
      country_code: country || null,
      notes: text(formData, "notes") || null,
      ...(text(formData, "also_other_role") === "on" && existing.kind !== "both"
        ? { kind: "both" as const }
        : {}),
    });
  } catch (error) {
    return errorState(error, "Perubahan tidak dapat disimpan. Periksa isian.");
  }
  revalidatePath(basePath);
  await setFlash("Perubahan kontak tersimpan.");
  redirect(
    entity
      ? `${basePath}/${contactId}?entity=${encodeURIComponent(entity)}`
      : `${basePath}/${contactId}`,
  );
}

/** Deactivate or reactivate a contact; history is kept either way. */
export async function setContactStatusAction(
  _previous: ContactActionState,
  formData: FormData,
): Promise<ContactActionState> {
  const entity = text(formData, "entity");
  const contactId = text(formData, "contact_id");
  const status = text(formData, "status") === "inactive" ? "inactive" : "active";
  try {
    const { membership } = await requirePermission("contacts.edit", { entityCode: entity });
    const existing = await getContact(contactId);
    if (!existing || existing.entity_id !== membership.entity_id) {
      return { status: "error", message: "Kontak tidak ditemukan." };
    }
    await setContactStatus(contactId, status);
  } catch (error) {
    return errorState(error, "Status kontak tidak dapat diubah.");
  }
  revalidatePath("/sales/customers");
  revalidatePath("/purchases/vendors");
  revalidatePath(`/sales/customers/${contactId}`);
  revalidatePath(`/purchases/vendors/${contactId}`);
  return {
    status: "ok",
    message: status === "inactive" ? "Kontak dinonaktifkan." : "Kontak diaktifkan kembali.",
  };
}
