import { z } from "zod";
import { idempotencyKeySchema } from "@/schemas/accounting";

/**
 * Input and output contracts of the generalized Documents Center RPCs (P11, Step 01 #34/#35/#43/#44,
 * Step 15 §15, Step 06 §5/§11, Step 08 §17/§21, Step 13 §16). The database owns the target-kind catalog,
 * every permission check, upload/download plumbing and version history (`supersedes_document_id` /
 * `replace_document_link`); this layer validates the input shape and what comes back, mapping the
 * database's error prefixes to `AuthzError` in `@/services/documents`. It holds no business rule of its
 * own. Labels live in `@/domain/documents`.
 */

/** The eleven target kinds registered in `app_private.document_target_kinds` (DECISIONS 141/147). */
export const documentTargetTypeSchema = z.enum([
  "bill",
  "expense",
  "invoice",
  "fixed_asset",
  "loan",
  "other_obligation",
  "equity_event",
  "contact",
  "journal_entry",
  "tax_filing",
  "tax_payment",
  "import_batch",
]);
export type DocumentTargetType = z.infer<typeof documentTargetTypeSchema>;

/**
 * The subset with `generic_linker = true` (DECISIONS 141/147): the kinds `link_document` /
 * `list_document_links` / `replace_document_link` accept. `tax_filing` and `tax_payment` keep their own
 * dedicated linker (`tax_link_evidence` / `tax_list_evidence` in `@/services/tax`) and are never passed
 * here — the database rejects them with INVALID if they are.
 */
export const genericLinkableTargetTypeSchema = z.enum([
  "bill",
  "expense",
  "invoice",
  "fixed_asset",
  "loan",
  "other_obligation",
  "equity_event",
  "contact",
  "journal_entry",
  "import_batch",
]);
export type GenericLinkableTargetType = z.infer<typeof genericLinkableTargetTypeSchema>;

export const documentPurposeSchema = z.enum(["vendor_invoice", "receipt", "contract", "other"]);
export type DocumentPurpose = z.infer<typeof documentPurposeSchema>;

/** The full MIME allowlist (`documents_mime_type_check`): evidence images/PDFs plus the two import file
 * types (a batch's raw upload is itself linkable evidence — Step 08 §17). */
export const documentMimeTypeSchema = z.enum([
  "application/pdf",
  "image/jpeg",
  "image/png",
  "image/webp",
  "text/csv",
  "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
]);
export type DocumentMimeType = z.infer<typeof documentMimeTypeSchema>;

export const MAX_DOCUMENT_BYTES = 25 * 1024 * 1024;

const fileNameSchema = z
  .string()
  .trim()
  .min(1)
  .max(255)
  // No path separators or control characters in a stored name.
  .regex(/^[^\\/\u0000-\u001f\u007f]+$/);

// ================================================================ register / upload
export const registerDocumentInputSchema = z.object({
  entity_id: z.uuid(),
  idempotency_key: idempotencyKeySchema,
  file_name: fileNameSchema,
  mime_type: documentMimeTypeSchema,
  size_bytes: z.number().int().positive().max(MAX_DOCUMENT_BYTES),
  sha256: z
    .string()
    .trim()
    .toLowerCase()
    .regex(/^[0-9a-f]{64}$/),
  /** A corrected file is a new document version, not an overwrite (Step 08 §21): `supersedes` names the
   * prior document, then `replace_document_link` swaps every link over to this one. */
  supersedes: z.uuid().optional(),
});

export const finalizeDocumentUploadInputSchema = z.object({
  document_id: z.uuid(),
  storage_path: z.string().trim().min(1).max(500),
});

// ================================================================ linking
export const linkDocumentInputSchema = z.object({
  document_id: z.uuid(),
  target_type: genericLinkableTargetTypeSchema,
  target_id: z.uuid(),
  purpose: documentPurposeSchema.optional(),
});

export const unlinkDocumentInputSchema = z.object({
  link_id: z.uuid(),
  reason: z.string().trim().min(3).max(1000),
});

export const replaceDocumentLinkInputSchema = z.object({
  link_id: z.uuid(),
  new_document_id: z.uuid(),
  reason: z.string().trim().max(1000).optional(),
});

export const listDocumentLinksInputSchema = z.object({
  entity_id: z.uuid(),
  target_type: genericLinkableTargetTypeSchema,
  target_id: z.uuid(),
});

export const documentLinkRowSchema = z.object({
  link_id: z.uuid(),
  document_id: z.uuid(),
  file_name: z.string(),
  mime_type: z.string(),
  size_bytes: z.coerce.number().int().positive(),
  sha256: z.string(),
  purpose: documentPurposeSchema,
  created_at: z.string(),
});
export const documentLinkListSchema = z.array(documentLinkRowSchema);
export type DocumentLinkRow = z.infer<typeof documentLinkRowSchema>;

// ================================================================ download
export const getDocumentDownloadGrantInputSchema = z.object({ document_id: z.uuid() });

export const documentDownloadGrantSchema = z.object({
  document_id: z.uuid(),
  file_name: z.string(),
  mime_type: z.string(),
  storage_path: z.string().nullable(),
});
export type DocumentDownloadGrant = z.infer<typeof documentDownloadGrantSchema>;

// ================================================================ Documents Center listing
export const listDocumentsInputSchema = z.object({
  entity_id: z.uuid(),
  target_type: documentTargetTypeSchema.optional(),
  q: z.string().trim().max(200).optional(),
  limit: z.number().int().min(1).max(200).optional(),
  offset: z.number().int().min(0).optional(),
});

export const documentRowSchema = z.object({
  document_id: z.uuid(),
  file_name: z.string(),
  mime_type: z.string(),
  size_bytes: z.coerce.number().int().positive(),
  sha256: z.string(),
  created_at: z.string(),
  link_count: z.coerce.number().int().nonnegative(),
  target_types: z.array(z.string()),
});
export const documentListSchema = z.array(documentRowSchema);
export type DocumentRow = z.infer<typeof documentRowSchema>;
