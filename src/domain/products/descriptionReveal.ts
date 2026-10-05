/**
 * Long product descriptions are shown cut to a few lines with a "Selengkapnya" reveal (task 95). Whether a
 * text is long enough to need the reveal is decided from its length -- measuring the rendered height would
 * need layout effects and flicker -- so a short description never shows a useless button.
 */
export const REVEAL_CHARACTER_LIMIT = 110;

export function needsReveal(
  text: string | null | undefined,
  limit = REVEAL_CHARACTER_LIMIT,
): boolean {
  if (!text) return false;
  const trimmed = text.trim();
  return trimmed.length > limit || trimmed.split(/\r?\n/).length > 2;
}
