import "server-only";
import { z, type ZodType } from "zod";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import { AuthzError, parseAuthzCode } from "@/domain/authz/errors";
import { uuidResultSchema } from "@/schemas/accounting";
import {
  documentDownloadGrantSchema,
  documentLinkListSchema,
  documentListSchema,
  finalizeDocumentUploadInputSchema,
  getDocumentDownloadGrantInputSchema,
  linkDocumentInputSchema,
  listDocumentLinksInputSchema,
  listDocumentsInputSchema,
  registerDocumentInputSchema,
  replaceDocumentLinkInputSchema,
  unlinkDocumentInputSchema,
  type DocumentDownloadGrant,
  type DocumentLinkRow,
  type DocumentRow,
} from "@/schemas/documents";

/**
 * Thin, typed wrappers over the generalized Documents Center RPCs (P11, Step 01 #34/#35/#43/#44,
 * Step 15 §15). Every call runs as the signed-in person; the database owns the target-kind catalog, every
 * permission check (`documents.upload`/`documents.view` plus the target's own view/edit permission),
 * content-hash dedup, version history and the download re-check (Step 06 §5: a storage path alone is not
 * permission). This layer validates the input shape, maps the database's error prefixes to AuthzError
 * without leaking detail, and validates what comes back. It holds no rule of its own. Labels live in
 * `@/domain/documents`.
 *
 * Uploading bytes to Supabase Storage is a separate concern from these RPCs (Step 13 §16): a caller
 * registers the document first (`registerDocument`), uploads the bytes to storage under a key it chooses,
 * then calls `finalizeDocumentUpload` to record where they landed. This module does not touch Storage
 * directly.
 */

async function callRpc<T>(
  name: string,
  args: Record<string, unknown>,
  schema: ZodType<T>,
): Promise<T> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc(name, args);
  if (error) {
    const code = parseAuthzCode(error.message);
    if (code) throw new AuthzError(code);
    throw new Error("Operasi dokumen gagal diproses.");
  }
  const parsed = schema.safeParse(data);
  if (!parsed.success) throw new Error("Respons dokumen tidak dikenali.");
  return parsed.data;
}

const textResult = z.string();

// ================================================================ register / upload
/** Registers a document by content hash (the same content in the same Entity is the same document). An
 * optional `supersedes` records this as a newer version of a prior document (Step 08 §21) — pair with
 * `replaceDocumentLink` to swap every existing link over to it. */
export async function registerDocument(
  input: z.input<typeof registerDocumentInputSchema>,
): Promise<string> {
  const v = registerDocumentInputSchema.parse(input);
  return callRpc(
    "register_document",
    {
      p_entity: v.entity_id,
      p_key: v.idempotency_key,
      p_file_name: v.file_name,
      p_mime_type: v.mime_type,
      p_size_bytes: v.size_bytes,
      p_sha256: v.sha256,
      p_supersedes: v.supersedes ?? null,
    },
    uuidResultSchema,
  );
}

/** Records where the uploaded bytes landed in Storage. `storage_path` is set exactly once — a corrected
 * file is a new document (`registerDocument` with `supersedes`), never an overwrite. */
export async function finalizeDocumentUpload(
  input: z.input<typeof finalizeDocumentUploadInputSchema>,
): Promise<void> {
  const v = finalizeDocumentUploadInputSchema.parse(input);
  await callRpc(
    "finalize_document_upload",
    { p_document: v.document_id, p_storage_path: v.storage_path },
    z.null(),
  );
}

// ================================================================ linking
export async function linkDocument(
  input: z.input<typeof linkDocumentInputSchema>,
): Promise<string> {
  const v = linkDocumentInputSchema.parse(input);
  return callRpc(
    "link_document",
    {
      p_document: v.document_id,
      p_target_type: v.target_type,
      p_target_id: v.target_id,
      p_purpose: v.purpose ?? "receipt",
    },
    uuidResultSchema,
  );
}

/** Evidence can be removed only while its target is in one of the target kind's `removable_statuses`. */
export async function unlinkDocument(
  input: z.input<typeof unlinkDocumentInputSchema>,
): Promise<string> {
  const v = unlinkDocumentInputSchema.parse(input);
  return callRpc("unlink_document", { p_link: v.link_id, p_reason: v.reason }, textResult);
}

/** Atomically swaps a link to a newer version of the same evidence (Step 08 §21): links the new document,
 * then removes the old link with the given (or a default) reason. */
export async function replaceDocumentLink(
  input: z.input<typeof replaceDocumentLinkInputSchema>,
): Promise<string> {
  const v = replaceDocumentLinkInputSchema.parse(input);
  return callRpc(
    "replace_document_link",
    { p_link: v.link_id, p_new_document: v.new_document_id, p_reason: v.reason ?? null },
    uuidResultSchema,
  );
}

export async function listDocumentLinks(
  input: z.input<typeof listDocumentLinksInputSchema>,
): Promise<DocumentLinkRow[]> {
  const v = listDocumentLinksInputSchema.parse(input);
  return callRpc(
    "list_document_links",
    { p_entity: v.entity_id, p_target_type: v.target_type, p_target_id: v.target_id },
    documentLinkListSchema,
  );
}

// ================================================================ download
/** Re-checks permission at download time (a storage path alone is not permission, Step 06 §5): granted
 * when the caller can view any active link's target, or the document has no links yet and the caller can
 * at least see the Documents module. Returns the storage path for the caller to mint a signed URL from. */
export async function getDocumentDownloadGrant(
  input: z.input<typeof getDocumentDownloadGrantInputSchema>,
): Promise<DocumentDownloadGrant> {
  const v = getDocumentDownloadGrantInputSchema.parse(input);
  const rows = await callRpc(
    "get_document_download_grant",
    { p_document: v.document_id },
    z.array(documentDownloadGrantSchema),
  );
  if (rows.length !== 1) throw new Error("Respons dokumen tidak dikenali.");
  return rows[0];
}

// ================================================================ Documents Center listing
export async function listDocuments(
  input: z.input<typeof listDocumentsInputSchema>,
): Promise<DocumentRow[]> {
  const v = listDocumentsInputSchema.parse(input);
  return callRpc(
    "list_documents",
    {
      p_entity: v.entity_id,
      p_target_type: v.target_type ?? null,
      p_q: v.q ?? null,
      p_limit: v.limit ?? 50,
      p_offset: v.offset ?? 0,
    },
    documentListSchema,
  );
}
