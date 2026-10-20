/**
 * Amounts as people type them in a chat ("85rb", "1,2jt", "Rp 50.000", "2 x 25k") and as the bot shows them back.
 * Pure: no I/O, no framework. Decision 422.
 */

export interface ParsedAmount {
  /** Whole rupiah. */
  value: number;
  /** Position of the token in the text (end is exclusive). */
  start: number;
  end: number;
  raw: string;
  /** Typed with a unit word (rb, jt, ...) or an "Rp" prefix: certainly money. */
  explicit: boolean;
}

const UNIT_MULTIPLIER: Record<string, number> = {
  rb: 1_000,
  ribu: 1_000,
  k: 1_000,
  jt: 1_000_000,
  juta: 1_000_000,
};

const MONTH_WORDS =
  "jan(?:uari)?|feb(?:ruari)?|mar(?:et)?|apr(?:il)?|mei|jun(?:i)?|jul(?:i)?|agu(?:stus)?|sep(?:t(?:ember)?)?|okt(?:ober)?|nov(?:ember)?|des(?:ember)?";

// A number with optional thousands/decimal separators, an optional "Rp" in front and an optional unit behind.
const AMOUNT_RE = new RegExp(
  String.raw`(?<![\w.,/-])(rp\.?\s*)?(\d{1,3}(?:[.,]\d{3})+|\d+(?:[.,]\d+)?)(?:\s*(rb|ribu|k|jt|juta)(?![a-z]))?`,
  "gi",
);

function digitsAfterLastSeparator(num: string): { sep: string; after: number } | null {
  const m = /[.,](\d+)$/.exec(num);
  if (!m || m[1] === undefined) return null;
  return { sep: num.charAt(num.length - m[1].length - 1), after: m[1].length };
}

/** Value of the digits in `num` (before any unit). Null when the token is not a sensible number. */
function numberValue(num: string): number | null {
  const separators = num.match(/[.,]/g) ?? [];
  let normalized: string;
  if (separators.length === 0) {
    normalized = num;
  } else if (num.includes(".") && num.includes(",")) {
    // "1.250,50": the LAST separator is the decimal one.
    const last = Math.max(num.lastIndexOf("."), num.lastIndexOf(","));
    normalized = num.slice(0, last).replace(/[.,]/g, "") + "." + num.slice(last + 1);
  } else if (separators.length > 1) {
    // "1.250.000" / "1,250,000": thousands separators.
    normalized = num.replace(/[.,]/g, "");
  } else {
    const tail = digitsAfterLastSeparator(num);
    if (!tail) return null;
    // One separator. Exactly three digits behind it means thousands ("50.000", "2.500rb"); one or two mean a
    // decimal ("1,2jt", "50,5").
    normalized = tail.after === 3 ? num.replace(/[.,]/g, "") : num.replace(",", ".");
  }
  const n = Number(normalized);
  return Number.isFinite(n) ? n : null;
}

function looksLikeYearInDate(text: string, start: number, end: number, value: number): boolean {
  if (value < 1990 || value > 2100) return false;
  const before = text.slice(Math.max(0, start - 12), start).toLowerCase();
  const after = text.slice(end, end + 3);
  return (
    new RegExp(`(?:${MONTH_WORDS})\\s*$`).test(before) ||
    /[/-]\s*$/.test(before) ||
    /^[/-]/.test(after)
  );
}

/** Every amount in `text`, left to right. Small bare numbers ("2 kopi", "tgl 20") are not money. */
export function parseAmounts(text: string): ParsedAmount[] {
  const found: ParsedAmount[] = [];
  AMOUNT_RE.lastIndex = 0;
  for (let m = AMOUNT_RE.exec(text); m !== null; m = AMOUNT_RE.exec(text)) {
    const rp = m[1];
    const num = m[2];
    const unit = m[3]?.toLowerCase();
    if (!num) continue;
    const base = numberValue(num);
    if (base === null) continue;
    const multiplier = unit ? (UNIT_MULTIPLIER[unit] ?? 1) : 1;
    const value = Math.round(base * multiplier);
    const explicit = Boolean(rp) || Boolean(unit);
    if (value <= 0) continue;
    const start = m.index;
    const end = m.index + m[0].length;
    // A phone number is not an amount.
    if (!explicit && /^(0|62)\d{8,}$/.test(num)) continue;
    if (!explicit && value < 1000) continue;
    if (!explicit && looksLikeYearInDate(text, start, end, value)) continue;
    found.push({ value, start, end, raw: m[0], explicit });
  }
  return found;
}

/** "Rp 1.250.000" (cents shown only when there are some: "Rp 427,81"). */
export function formatRupiah(amount: number | string): string {
  const n = typeof amount === "string" ? Number(amount) : amount;
  if (!Number.isFinite(n)) return "Rp 0";
  const negative = n < 0;
  const abs = Math.abs(n);
  const whole = Math.floor(abs + 1e-9);
  const cents = Math.round((abs - whole) * 100);
  const grouped = String(cents === 100 ? whole + 1 : whole).replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  const tail = cents > 0 && cents < 100 ? `,${String(cents).padStart(2, "0")}` : "";
  return `${negative ? "-" : ""}Rp ${grouped}${tail}`;
}
