import "server-only";
import { createSupabaseAdminClient } from "@/lib/supabase/admin";

/**
 * The bytes of evidence files in the private `documents` bucket (Step 13 §16, decisions 142/275). Callers
 * must have obtained the database's consent first: `register_document` before `storeDocumentBytes`,
 * `get_document_download_grant` before `signedDocumentUrl`.
 */

const BUCKET = "documents";
const SIGNED_URL_SECONDS = 60;

export function documentStorageEnabled(): boolean {
  return createSupabaseAdminClient() !== null;
}

/** One object per document: the same content in an Entity is one document, so one object. */
export function documentObjectPath(entityId: string, documentId: string): string {
  return `${entityId}/${documentId}`;
}

export async function storeDocumentBytes(
  path: string,
  bytes: ArrayBuffer,
  mimeType: string,
): Promise<boolean> {
  const admin = createSupabaseAdminClient();
  if (!admin) return false;
  const { error } = await admin.storage
    .from(BUCKET)
    .upload(path, bytes, { contentType: mimeType, upsert: true });
  return !error;
}

export async function signedDocumentUrl(path: string, fileName: string): Promise<string | null> {
  const admin = createSupabaseAdminClient();
  if (!admin) return null;
  const { data, error } = await admin.storage
    .from(BUCKET)
    .createSignedUrl(path, SIGNED_URL_SECONDS, { download: fileName });
  if (error || !data) return null;
  return data.signedUrl;
}
