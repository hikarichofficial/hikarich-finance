import { Decimal } from "@/domain/money/decimal";
import { currencyScale } from "@/domain/money/currency";

/**
 * Display formatting for exact decimal text (Step 10, Indonesian conventions: "." between thousands, "," before
 * the decimals). It works on the digits of the text, never on a floating-point number, so a large or precise
 * amount is shown exactly as stored.
 */

function group(digits: string): string {
  return digits.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
}

/** "1234567.5" with scale 2 -> "1.234.567,50". Negative values keep their minus sign. */
export function formatDecimal(text: string, scale: number): string {
  const fixed = Decimal.parse(text).toFixed(scale);
  const negative = fixed.startsWith("-");
  const unsigned = negative ? fixed.slice(1) : fixed;
  const [whole, fraction] = unsigned.split(".");
  return `${negative ? "-" : ""}${group(whole)}${fraction ? `,${fraction}` : ""}`;
}

/** "1234567.5" in IDR -> "Rp 1.234.567,50"; other currencies show their ISO code in front. */
export function formatMoney(text: string, currency: string): string {
  const body = formatDecimal(text, currencyScale(currency));
  if (currency === "IDR") return body.startsWith("-") ? `-Rp ${body.slice(1)}` : `Rp ${body}`;
  return `${currency} ${body}`;
}

/** Quantity or unit price as stored, without trailing zeros: "2.5000" -> "2,5". */
export function formatPlain(text: string): string {
  const parsed = Decimal.parse(text);
  const trimmed = parsed
    .toString()
    .replace(/(\.\d*?)0+$/, "$1")
    .replace(/\.$/, "");
  const negative = trimmed.startsWith("-");
  const unsigned = negative ? trimmed.slice(1) : trimmed;
  const [whole, fraction] = unsigned.split(".");
  return `${negative ? "-" : ""}${group(whole)}${fraction ? `,${fraction}` : ""}`;
}

/**
 * A price shown exactly: at least the currency's own decimals, and any further digits the stored value really
 * has ("0.0050" in IDR -> "Rp 0,005"). A unit price can carry more decimals than a total, and a rounded display
 * would then disagree with the line total next to it.
 */
export function formatMoneyExact(text: string, currency: string): string {
  const scale = currencyScale(currency);
  const stored = Decimal.parse(text).toString();
  const dot = stored.indexOf(".");
  const digits = dot < 0 ? 0 : stored.slice(dot + 1).replace(/0+$/, "").length;
  const body = formatDecimal(text, Math.max(scale, digits));
  if (currency === "IDR") return body.startsWith("-") ? `-Rp ${body.slice(1)}` : `Rp ${body}`;
  return `${currency} ${body}`;
}
