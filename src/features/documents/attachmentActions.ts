"use server";

import { createHash, randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import {
  ATTACHMENT_MAX_BYTES,
  safeFileName,
  sniffAttachmentType,
} from "@/domain/documents/fileSignature";
import { documentPurposeSchema, genericLinkableTargetTypeSchema } from "@/schemas/documents";
import { requirePermission } from "@/services/identity/access";
import {
  createDocumentPurpose,
  finalizeDocumentUpload,
  getDocumentDownloadGrant,
  linkDocument,
  registerDocument,
  unlinkDocument,
} from "@/services/documents/documents";
import {
  documentObjectPath,
  documentStorageEnabled,
  storeDocumentBytes,
} from "@/services/documents/storage";
import type { AttachmentActionState } from "./attachmentActionsState";

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
  const file = formData.get("file");
  if (!target.success || !(file instanceof File) || file.size === 0) {
    return { status: "error", message: "Pilih berkas yang akan dilampirkan." };
  }
  if (file.size > ATTACHMENT_MAX_BYTES) {
    return { status: "error", message: "Berkas terlalu besar. Ukuran maksimal 4 MB." };
  }
  if (!documentStorageEnabled()) {
    return { status: "error", message: "Penyimpanan berkas belum diaktifkan untuk situs ini." };
  }
  const buffer = await file.arrayBuffer();
  const mimeType = sniffAttachmentType(new Uint8Array(buffer.slice(0, 16)));
  if (!mimeType) {
    return { status: "error", message: "Jenis berkas harus PDF, JPG, PNG atau WebP." };
  }
  try {
    const { membership } = await requirePermission("documents.upload", { entityCode: entity });
    const documentId = await registerDocument({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      file_name: safeFileName(file.name),
      mime_type: mimeType,
      size_bytes: file.size,
      sha256: createHash("sha256").update(Buffer.from(buffer)).digest("hex"),
    });
    // The same content registered before is the same document; its bytes are stored once.
    const grant = await getDocumentDownloadGrant({ document_id: documentId });
    if (!grant.storage_path) {
      const path = documentObjectPath(membership.entity_id, documentId);
      if (!(await storeDocumentBytes(path, buffer, mimeType))) {
        return { status: "error", message: "Berkas tidak dapat disimpan. Coba lagi." };
      }
      await finalizeDocumentUpload({ document_id: documentId, storage_path: path });
    }
    await linkDocument({
      document_id: documentId,
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
