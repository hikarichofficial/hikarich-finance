import sharp from "sharp";

/** The largest upload accepted before shrinking (the server action body limit is 5 MB). */
export const LOGO_MAX_UPLOAD_BYTES = 4 * 1024 * 1024;
/** A logo is drawn at most about 180x72 px on a document; this keeps it sharp on high-density screens. */
const MAX_WIDTH = 600;
const MAX_HEIGHT = 240;
/** The stored logo is shrunk until it is at most this many bytes (typically 5-40 KB). */
const TARGET_BYTES = 60_000;
const QUALITIES = [85, 72, 58, 45, 32];
const SCALES = [1, 0.75, 0.5, 0.35];
const ALLOWED_FORMATS = new Set(["png", "jpeg", "webp"]);

export class LogoImageError extends Error {}

export interface CompressedLogo {
  dataUrl: string;
  bytes: number;
  width: number;
  height: number;
}

/**
 * Turns an uploaded logo into a small WebP (OWNER, 6 October 2026: "logo yang di upload dikompres supaya tidak
 * membebani storage"). The file's real content decides what it is, not its name or declared type: only PNG, JPEG
 * and WebP images are accepted (an SVG, which can carry script, is refused), a rotated photo is turned upright,
 * the picture is shrunk to fit 600x240 px (never enlarged), transparency is kept, and quality steps down until
 * the result is at most 60 KB. The original is not stored.
 */
export async function compressLogo(input: Buffer): Promise<CompressedLogo> {
  if (input.length === 0 || input.length > LOGO_MAX_UPLOAD_BYTES) {
    throw new LogoImageError("size");
  }
  try {
    const meta = await sharp(input, { limitInputPixels: 40_000_000 }).metadata();
    if (!meta.format || !ALLOWED_FORMATS.has(meta.format)) throw new LogoImageError("format");

    // Quality steps down first; a picture that is still too heavy (a photograph, noise) is then made smaller.
    let last: { data: Buffer; info: { width: number; height: number } } | null = null;
    search: for (const scale of SCALES) {
      for (const quality of QUALITIES) {
        last = await sharp(input, { limitInputPixels: 40_000_000, failOn: "error" })
          .rotate()
          .resize({
            width: Math.round(MAX_WIDTH * scale),
            height: Math.round(MAX_HEIGHT * scale),
            fit: "inside",
            withoutEnlargement: true,
          })
          .webp({ quality, alphaQuality: 90, effort: 4 })
          .toBuffer({ resolveWithObject: true });
        if (last.data.length <= TARGET_BYTES) break search;
      }
    }
    if (!last) throw new LogoImageError("format");
    return {
      dataUrl: `data:image/webp;base64,${last.data.toString("base64")}`,
      bytes: last.data.length,
      width: last.info.width,
      height: last.info.height,
    };
  } catch (error) {
    if (error instanceof LogoImageError) throw error;
    throw new LogoImageError("format");
  }
}
