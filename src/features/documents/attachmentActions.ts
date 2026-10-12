"use server";

import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { documentPurposeSchema, genericLinkableTargetTypeSchema } from "@/schemas/documents";
import { requirePermission } from "@/services/identity/access";
import {
  createDocumentPurpose,
  linkDocument,
  renameDocumentPurpose,
  setDocumentPurposeActive,
  unlinkDocument,
} from "@/services/documents/documents";
import type { AttachmentActionState } from "./attachmentActionsState";
import { storeUploadedFile } from "./storeUploadedFile";

/**
 * Attach a file to a record and remove an attachment (Step 08 §21, Step 13 §16, decisions 141-142, 275).
 * The database decides everything: `register_document` (permission, one document per content),
 * `finalize_document_upload`, `link_document` / `unlink_document` (which records accept or release
 * evidence in which status). This layer checks the file's real type and size, computes its SHA-256 and
 * puts the bytes in the private bucket between "registered" and "finalized".
 */

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): AttachmentActionState {
  if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
  return { status: "error", message: fallback };
}

export async function uploadAttachmentAction(
  _previous: AttachmentActionState,
  formData: FormData,
): Promise<AttachmentActionState> {
  const entity = text(formData, "entity");
  const target = genericLinkableTargetTypeSchema.safeParse(text(formData, "target_type"));
  const purpose = documentPurposeSchema.safeParse(text(formData, "purpose"));
  const targetId = text(formData, "target_id");
  if (!target.success) {
    return { status: "error", message: "Pilih berkas yang akan dilampirkan." };
  }
  try {
    const stored = await storeUploadedFile(formData.get("file"), entity);
    if (!stored.ok) return { status: "error", message: stored.message };
    await linkDocument({
      document_id: stored.documentId,
      target_type: target.data,
      target_id: targetId,
      purpose: purpose.success ? purpose.data : "other",
    });
  } catch (error) {
    return errorState(error, "Lampiran tidak dapat disimpan.");
  }
  revalidatePath(text(formData, "return_path") || "/documents");
  return { status: "ok", message: "Lampiran tersimpan." };
}

export async function removeAttachmentAction(
  _previous: AttachmentActionState,
  formData: FormData,
): Promise<AttachmentActionState> {
  const reason = text(formData, "reason");
  if (reason.length < 3) return { status: "error", message: "Tulis alasan melepas lampiran." };
  try {
    await unlinkDocument({ link_id: text(formData, "link_id"), reason });
  } catch (error) {
    return errorState(error, "Lampiran tidak dapat dilepas.");
  }
  revalidatePath(text(formData, "return_path") || "/documents");
  return { status: "ok", message: "Lampiran dilepas." };
}

/** Adds an attachment type from inside the upload form and hands it back, so it can be chosen at once. */
export async function createDocumentPurposeAction(
  entity: string,
  name: string,
): Promise<
  { status: "ok"; purpose: { id: string; name: string } } | { status: "error"; message: string }
> {
  const tidy = name.replace(/\s+/g, " ").trim();
  if (tidy.length < 2 || tidy.length > 60) {
    return { status: "error", message: "Nama jenis lampiran 2 sampai 60 karakter." };
  }
  try {
    const { membership } = await requirePermission("documents.upload", { entityCode: entity });
    const id = await createDocumentPurpose({ entity_id: membership.entity_id, name: tidy });
    return { status: "ok", purpose: { id, name: tidy } };
  } catch (error) {
    if (error instanceof AuthzError) return { status: "error", message: describeAuthzError(error) };
    return { status: "error", message: "Jenis lampiran tidak dapat disimpan." };
  }
}

/**
 * Renaming an attachment type and taking one out of use (decision 401). Both need `documents.upload`, the
 * same right that adds one; the database re-checks it and owns the name rules, so these only tidy the input
 * and turn a refusal into a sentence.
 */
export async function renameDocumentPurposeAction(
  _previous: AttachmentActionState,
  formData: FormData,
): Promise<AttachmentActionState> {
  const tidy = text(formData, "name").replace(/\s+/g, " ").trim();
  if (tidy.length < 2 || tidy.length > 60) {
    return { status: "error", message: "Nama jenis lampiran 2 sampai 60 karakter." };
  }
  try {
    await renameDocumentPurpose({ purpose_id: text(formData, "purpose_id"), name: tidy });
  } catch (error) {
    return errorState(error, "Jenis lampiran tidak dapat diubah.");
  }
  revalidatePath(text(formData, "return_path") || "/documents");
  return { status: "ok", message: "Nama jenis lampiran diubah." };
}

export async function setDocumentPurposeActiveAction(
  _previous: AttachmentActionState,
  formData: FormData,
): Promise<AttachmentActionState> {
  const active = text(formData, "active") === "true";
  try {
    await setDocumentPurposeActive({ purpose_id: text(formData, "purpose_id"), active });
  } catch (error) {
    return errorState(error, "Jenis lampiran tidak dapat diubah.");
  }
  revalidatePath(text(formData, "return_path") || "/documents");
  return {
    status: "ok",
    message: active ? "Jenis lampiran dipakai lagi." : "Jenis lampiran tidak dipakai lagi.",
  };
}
