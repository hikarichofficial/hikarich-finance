import { createHash, randomUUID } from "node:crypto";
import {
  ATTACHMENT_MAX_BYTES,
  safeFileName,
  sniffAttachmentType,
} from "@/domain/documents/fileSignature";
import { requirePermission } from "@/services/identity/access";
import {
  finalizeDocumentUpload,
  getDocumentDownloadGrant,
  registerDocument,
} from "@/services/documents/documents";
import {
  documentObjectPath,
  documentStorageEnabled,
  storeDocumentBytes,
} from "@/services/documents/storage";

/**
 * The one way a file becomes a registered document (decision 411): check its real type and size, register it
 * (one document per content), put the bytes in the private bucket and finalize. Every upload in the app goes
 * through here, so a file is checked and stored the same way wherever it is attached (a record's "Lampiran",
 * the tax evidence); what the file is then linked to is the caller's business. An `AuthzError` from the
 * database is thrown for the caller to turn into a message; the checks of the file itself come back as
 * `{ ok: false }`.
 */
export type StoreUploadedFileResult =
  { ok: true; documentId: string; entityId: string } | { ok: false; message: string };

export async function storeUploadedFile(
  file: FormDataEntryValue | null,
  entityCode: string,
): Promise<StoreUploadedFileResult> {
  if (!(file instanceof File) || file.size === 0) {
    return { ok: false, message: "Pilih berkas yang akan dilampirkan." };
  }
  if (file.size > ATTACHMENT_MAX_BYTES) {
    return { ok: false, message: "Berkas terlalu besar. Ukuran maksimal 4 MB." };
  }
  if (!documentStorageEnabled()) {
    return { ok: false, message: "Penyimpanan berkas belum diaktifkan untuk situs ini." };
  }
  const buffer = await file.arrayBuffer();
  const mimeType = sniffAttachmentType(new Uint8Array(buffer.slice(0, 16)));
  if (!mimeType) {
    return { ok: false, message: "Jenis berkas harus PDF, JPG, PNG atau WebP." };
  }
  const { membership } = await requirePermission("documents.upload", { entityCode });
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
      return { ok: false, message: "Berkas tidak dapat disimpan. Coba lagi." };
    }
    await finalizeDocumentUpload({ document_id: documentId, storage_path: path });
  }
  return { ok: true, documentId, entityId: membership.entity_id };
}
