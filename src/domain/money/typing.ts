/**
 * Live formatting of an amount while a person types it (OWNER, 5 October 2026: every price field shows a
 * thousands separator by itself -- "100000000" appears as "100.000.000" -- and a comma is what starts the
 * decimals). The text the form keeps and sends stays the plain decimal text the rest of the system reads
 * ("100000000", "1500.5"); only the visible text carries the separators.
 *
 * While typing, every "." is a thousands mark the field inserts itself, so it is ignored; "," is the only
 * decimal mark. A value pasted from elsewhere goes through `parseMoneyInput` instead (it can tell "1.500"
 * from "1.5"), and the result is shown the same way.
 */

const MAX_WHOLE_DIGITS = 16;
const MAX_DECIMAL_DIGITS = 4;

/** What a person has typed into the field -> the plain decimal text ("" when nothing is there yet). A
 * trailing "." is kept ("1000." while the comma was just typed) so the comma stays visible until the next
 * digit; `plainMoneyText` drops it for submission. */
export function canonicalFromTyping(raw: string): string {
  const cleaned = raw.replace(/[^\d,]/g, "");
  if (cleaned === "") return "";
  const comma = cleaned.indexOf(",");
  const wholeRaw = comma < 0 ? cleaned : cleaned.slice(0, comma);
  const fractionRaw = comma < 0 ? "" : cleaned.slice(comma + 1).replace(/,/g, "");
  const whole = wholeRaw.replace(/^0+(?=\d)/, "").slice(0, MAX_WHOLE_DIGITS);
  if (comma < 0) return whole;
  return `${whole === "" ? "0" : whole}.${fractionRaw.slice(0, MAX_DECIMAL_DIGITS)}`;
}

/** Plain decimal text -> what the field shows: "100000000" -> "100.000.000", "1500.5" -> "1.500,5". */
export function formatMoneyTyping(canonical: string): string {
  if (canonical === "") return "";
  const dot = canonical.indexOf(".");
  const whole = dot < 0 ? canonical : canonical.slice(0, dot);
  const grouped = whole.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  return dot < 0 ? grouped : `${grouped},${canonical.slice(dot + 1)}`;
}

/** The text a form submits: no dangling decimal mark. */
export function plainMoneyText(canonical: string): string {
  return canonical.endsWith(".") ? canonical.slice(0, -1) : canonical;
}

/** Where the caret belongs in the new display text so it stays after the same digits the person had typed
 * before it, however many separators the formatting inserted or removed. */
export function caretAfterFormatting(rawBeforeCaret: string, display: string): number {
  const wanted = rawBeforeCaret.replace(/[^\d,]/g, "").length;
  if (wanted === 0) return 0;
  let seen = 0;
  for (let index = 0; index < display.length; index += 1) {
    if (display[index] !== ".") seen += 1;
    if (seen === wanted) return index + 1;
  }
  return display.length;
}
