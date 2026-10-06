"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import { createPaymentLink, updatePaymentLink } from "@/services/sales/paymentLinks";

/**
 * Server actions behind the Tautan Pembayaran screen and the add-on-the-spot form on Buat Invoice
 * (decision 307). The database checks the permission (`invoices.create`), the https address and the name.
 */

export interface PaymentLinkActionState {
  status: "idle" | "ok" | "error";
  message?: string;
}

export interface QuickPaymentLinkState extends PaymentLinkActionState {
  link?: { id: string; name: string };
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

const FALLBACK =
  "Tautan tidak dapat disimpan. Nama 2 sampai 120 karakter; alamat harus diawali https:// dan tanpa spasi.";

function errorMessage(error: unknown): string {
  return error instanceof AuthzError ? describeAuthzError(error) : FALLBACK;
}

export async function createPaymentLinkAction(
  _previous: PaymentLinkActionState,
  formData: FormData,
): Promise<PaymentLinkActionState> {
  try {
    const { membership } = await requirePermission("invoices.create", {
      entityCode: text(formData, "entity"),
    });
    await createPaymentLink({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      name: text(formData, "name"),
      url: text(formData, "url"),
    });
  } catch (error) {
    return { status: "error", message: errorMessage(error) };
  }
  revalidatePath("/sales/payment-links");
  return { status: "ok", message: "Tautan pembayaran tersimpan." };
}

/** The same write from Buat Invoice: returns the new link so the form can select it without a reload. */
export async function quickCreatePaymentLinkAction(
  _previous: QuickPaymentLinkState,
  formData: FormData,
): Promise<QuickPaymentLinkState> {
  const name = text(formData, "name");
  try {
    const { membership } = await requirePermission("invoices.create", {
      entityCode: text(formData, "entity"),
    });
    const id = await createPaymentLink({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      name,
      url: text(formData, "url"),
    });
    revalidatePath("/sales/payment-links");
    return { status: "ok", message: "Tautan pembayaran tersimpan.", link: { id, name } };
  } catch (error) {
    return { status: "error", message: errorMessage(error) };
  }
}

export async function updatePaymentLinkAction(
  _previous: PaymentLinkActionState,
  formData: FormData,
): Promise<PaymentLinkActionState> {
  try {
    const { membership } = await requirePermission("invoices.create", {
      entityCode: text(formData, "entity"),
    });
    await updatePaymentLink({
      entity_id: membership.entity_id,
      id: text(formData, "id"),
      name: text(formData, "name"),
      url: text(formData, "url"),
      active: text(formData, "active") === "on",
    });
  } catch (error) {
    return { status: "error", message: errorMessage(error) };
  }
  revalidatePath("/sales/payment-links");
  return { status: "ok", message: "Tautan pembayaran diperbarui." };
}
