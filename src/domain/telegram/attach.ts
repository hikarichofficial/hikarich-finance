/**
 * Attaching a photo to an entry that is already on the website (decision 424): the owner names it by its transaction
 * number, for example EXP-001-0003. Pure text reading; the lookup and the permission checks are the database's.
 */

const CODE = /\b([a-z]{2,6}(?:-[a-z0-9]{1,8}){1,3}-\d{1,8}|[a-z]{2,6}-\d{1,8})\b/i;
const WORD = /\b(?:lampir(?:kan|an)?|attach(?:ment)?|tambahkan\s+(?:foto|lampiran))\b/i;

/** The transaction number written in the text, upper-cased, or null. */
export function extractExpenseCode(text: string): string | null {
  const m = CODE.exec(text);
  return m?.[1] ? m[1].toUpperCase() : null;
}

/** Whether the text says "lampirkan" or "attach". */
export function hasAttachWord(text: string): boolean {
  return WORD.test(text);
}

/** Whether the caption asks to attach the photo to an existing entry: it names a number or says "lampirkan". */
export function wantsAttachment(text: string): boolean {
  return text.length > 0 && (WORD.test(text) || extractExpenseCode(text) !== null);
}
