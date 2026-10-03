import type { DocumentMimeType } from "@/schemas/documents";

/** Attachments go through a Server Action; Vercel's request ceiling is 4.5 MB. */
export const ATTACHMENT_MAX_BYTES = 4 * 1024 * 1024;

export const ATTACHMENT_ACCEPT = ".pdf,.jpg,.jpeg,.png,.webp";

/**
 * The file type read from the first bytes of the content, not from the name or the browser's claim
 * (decision 142: file-signature screening is the application's job). Only the types an attachment may
 * have; anything else is `null` and refused.
 */
export function sniffAttachmentType(bytes: Uint8Array): DocumentMimeType | null {
  const starts = (...signature: number[]) => signature.every((byte, i) => bytes[i] === byte);
  if (starts(0x25, 0x50, 0x44, 0x46, 0x2d)) return "application/pdf";
  if (starts(0xff, 0xd8, 0xff)) return "image/jpeg";
  if (starts(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a)) return "image/png";
  if (
    starts(0x52, 0x49, 0x46, 0x46) &&
    bytes[8] === 0x57 &&
    bytes[9] === 0x45 &&
    bytes[10] === 0x42 &&
    bytes[11] === 0x50
  ) {
    return "image/webp";
  }
  return null;
}

/** A stored name has no path separators or control characters (`documents` check constraint). */
export function safeFileName(name: string): string {
  const cleaned = name
    .replace(/[\\/]/g, "-")
    .replace(/[\u0000-\u001f\u007f]/g, "")
    .trim()
    .slice(0, 255);
  return cleaned === "" ? "lampiran" : cleaned;
}
