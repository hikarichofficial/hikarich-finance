/**
 * Reading a chat message the way a person wrote it: what to do with it (intent) and, for an expense, the lines,
 * date, payee, Entity word and payment account it mentions. Rule-based and pure; the AI is only asked when this
 * finds nothing to work with. Decision 422.
 */
import { containsWord, normalizeText } from "./categorize";
import { parseDateHint } from "./dates";
import { parseAmounts } from "./rupiah";

export type EntityWord = "company" | "personal";

export interface ParsedLine {
  description: string;
  /** Whole rupiah for the line (quantity already applied). */
  amount: number;
  quantity: number;
}

export interface ParsedExpense {
  lines: ParsedLine[];
  total: number;
  /** ISO date when the message names one, else null (the caller uses today). */
  date: string | null;
  payee: string | null;
  entityWord: EntityWord | null;
  /** Words that point at a payment account ("gopay", "bca", "tunai"), normalized. */
  accountWords: string[];
}

export type Intent =
  | { kind: "command"; name: string; arg: string }
  | { kind: "undo" }
  | { kind: "report"; text: string }
  | { kind: "help" }
  | { kind: "record" }
  | { kind: "chat" };

const COMPANY_WORDS = [
  "pt",
  "perusahaan",
  "usaha",
  "bisnis",
  "kantor pt",
  "hikarich",
  "company",
  "business",
  "my company",
];
const PERSONAL_WORDS = [
  "pribadi",
  "pribadiku",
  "personal",
  "sendiri",
  "uang pribadi",
  "my own money",
];

const NOT_A_PAYEE = new Set([
  "kantor",
  "rumah",
  "sana",
  "sini",
  "bandara",
  "bank",
  "stasiun",
  "pasar",
  "jakarta",
  "bali",
  "makassar",
  "bandung",
  "surabaya",
  "toko",
  "warung",
  "tempat",
  "situ",
  "tadi",
  "pt",
  "pribadi",
  "atm",
]);

const ACCOUNT_WORDS = [
  "tunai",
  "cash",
  "kas",
  "dana",
  "gopay",
  "ovo",
  "shopeepay",
  "linkaja",
  "qris",
  "transfer",
  "bca",
  "bni",
  "bri",
  "mandiri",
  "cimb",
  "permata",
  "jago",
  "seabank",
  "blu",
  "jenius",
  "debit",
  "kartu",
  "rekening",
  "e-wallet",
  "ewallet",
  "apple pay",
  "applepay",
  "tabungan",
];

const LEADING_NOISE =
  /^(?:tolong\s+|mohon\s+)?(?:catat(?:kan)?\s+|input\s+|masukkan\s+|tambah(?:kan)?\s+)?(?:pengeluaran\s+)?(?:tadi\s+|barusan\s+)?(?:saya\s+|aku\s+|gue\s+|gw\s+)?(?:udah\s+|sudah\s+)?(?:beli|bayar|bayarin|belanja|transfer|top\s?up|isi|keluar|ngeluarin|habis|abis)?\s*/i;

/** "2x25rb" -> "2 x 25rb"; tabs and doubled spaces folded. */
export function normalizeMessage(text: string): string {
  return text
    .replace(/(\d)\s*[x×]\s*(?=\d|rp)/gi, "$1 x ")
    .replace(/[ \t]+/g, " ")
    .trim();
}

/** What the sender wants, from the shape of the message. */
export function classifyIntent(raw: string): Intent {
  const text = raw.trim();
  if (text.startsWith("/")) {
    const m = /^\/([a-z0-9_]+)(?:@\w+)?(?:\s+([\s\S]*))?$/i.exec(text);
    if (m?.[1]) return { kind: "command", name: m[1].toLowerCase(), arg: (m[2] ?? "").trim() };
  }
  const norm = normalizeText(text);
  if (
    /^(?:batal(?:kan)?|hapus|undo|cancel|delete|remove|wrong|salah)\b/.test(norm) &&
    /\b(?:tadi|terakhir|barusan|itu|yang|last|that|previous|latest)\b|^(?:undo|batal|batalkan|cancel)$/.test(
      norm,
    )
  ) {
    return { kind: "undo" };
  }
  if (
    /^(?:help|bantuan|menu|tolong|bisa apa|apa saja yang bisa|what can you do)\b/.test(norm) &&
    parseAmounts(text).length === 0
  ) {
    return { kind: "help" };
  }
  const asksReport =
    /\b(?:ringkasan|laporan|rekap|rangkuman|summary|report|total|berapa|how much|habis berapa|pengeluaran|expenses|spent|spending)\b/.test(
      norm,
    ) && parseAmounts(text).filter((a) => a.explicit).length === 0;
  if (
    asksReport &&
    (/\?/.test(text) ||
      /\b(?:hari|minggu|bulan|tahun|kemarin|ini|lalu|terakhir|tgl|senin|selasa|rabu|kamis|jumat|sabtu|today|yesterday|week|month|year|last|this|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b/.test(
        norm,
      ) ||
      /^(?:ringkasan|laporan|rekap|rangkuman|summary|report)\b/.test(norm))
  ) {
    return { kind: "report", text };
  }
  if (parseAmounts(text).length > 0) return { kind: "record" };
  return { kind: "chat" };
}

export function entityWordOf(text: string): EntityWord | null {
  const personal = PERSONAL_WORDS.some((w) => containsWord(text, w));
  const company = COMPANY_WORDS.some((w) => containsWord(text, w));
  if (personal && !company) return "personal";
  if (company && !personal) return "company";
  return null;
}

function accountWordsOf(text: string): string[] {
  return ACCOUNT_WORDS.filter((w) => containsWord(text, w)).map((w) => normalizeText(w));
}

function payeeOf(text: string): string | null {
  const m =
    /\b(?:di|ke|dari|pada)\s+([a-z0-9][\w&'./-]*(?:\s+[a-z0-9][\w&'./-]*){0,3}?)(?=\s+(?:pakai|pake|via|dengan|pake|untuk|buat|kemarin|tadi|pt|pribadi|rp\.?\s*\d|\d)|[,.;\n]|$)/i.exec(
      text,
    );
  const candidate = m?.[1]?.trim();
  if (!candidate) return null;
  const first = normalizeText(candidate).split(" ")[0] ?? "";
  if (NOT_A_PAYEE.has(first) && normalizeText(candidate).split(" ").length === 1) return null;
  if (candidate.length < 2 || candidate.length > 60) return null;
  return titleCase(candidate);
}

function titleCase(value: string): string {
  return value
    .split(/\s+/)
    .map((w) =>
      w === w.toUpperCase() && w.length <= 4 ? w : w.charAt(0).toUpperCase() + w.slice(1),
    )
    .join(" ");
}

/** Removes the pieces of a segment that are not the description of what was bought. */
function cleanDescription(segment: string, removals: Array<[number, number]>): string {
  let out = "";
  let cursor = 0;
  for (const [s, e] of [...removals].sort((a, b) => a[0] - b[0])) {
    if (s < cursor) continue;
    out += segment.slice(cursor, s) + " ";
    cursor = e;
  }
  out += segment.slice(cursor);
  out = out
    .replace(
      /\b(?:pakai|pake|pakek|via|dengan|lewat|dari)\s+(?:[a-z0-9-]+(?:\s+pay)?)(?=\s|$)/gi,
      (hit) => {
        const word = normalizeText(hit.replace(/^\S+\s+/, ""));
        return ACCOUNT_WORDS.some((w) => normalizeText(w) === word) ? " " : hit;
      },
    )
    .replace(/\b(?:pt|pribadi|pribadiku|personal|perusahaan)\b/gi, " ")
    .replace(
      /\b(?:tadi(?:\s+(?:pagi|siang|sore|malam))?|barusan|kemarin(?:\s+lusa)?|hari ini)\b/gi,
      " ",
    )
    .replace(/\b(?:rp\.?|sebesar|senilai|seharga|total|harga|sekitar)\b/gi, " ")
    .replace(/\bx\s*$/i, " ")
    .replace(/[\s,;:+\-–]+/g, " ")
    .trim();
  out = out
    .replace(LEADING_NOISE, "")
    .replace(/^(?:untuk|buat|utk)\s+/i, "")
    .trim();
  return out;
}

interface Piece {
  text: string;
  /** Offset of the piece inside the full message (for date removal). */
  offset: number;
}

function splitIntoPieces(text: string): Piece[] {
  const pieces: Piece[] = [];
  const separator = /\n|;|\s\+\s|,\s+(?=[a-z])|\s(?:dan|sama|plus|terus|lalu)\s/gi;
  let cursor = 0;
  for (let m = separator.exec(text); m !== null; m = separator.exec(text)) {
    pieces.push({ text: text.slice(cursor, m.index), offset: cursor });
    cursor = m.index + m[0].length;
  }
  pieces.push({ text: text.slice(cursor), offset: cursor });
  return pieces.filter((p) => p.text.trim().length > 0);
}

/** Reads an expense out of free text. Null when no amount can be found. */
export function parseExpenseText(rawText: string, today: string): ParsedExpense | null {
  const text = normalizeMessage(rawText);
  if (text.length === 0 || text.length > 2000) return null;
  const date = parseDateHint(text, today);
  const entityWord = entityWordOf(text);
  const accountWords = accountWordsOf(text);
  const payee = payeeOf(text);

  const dateRange: Array<[number, number]> = date ? [[date.start, date.end]] : [];
  const lines: ParsedLine[] = [];
  let carry = "";

  for (const piece of splitIntoPieces(text)) {
    const amounts = parseAmounts(piece.text);
    const removalsFor = (start: number, end: number): Array<[number, number]> =>
      dateRange
        .map(([s, e]): [number, number] => [s - piece.offset - start, e - piece.offset - start])
        .filter(([s, e]) => e > 0 && s < end - start);

    if (amounts.length === 0) {
      const leftover = cleanDescription(piece.text, removalsFor(0, piece.text.length));
      if (leftover) carry = carry ? `${carry} ${leftover}` : leftover;
      continue;
    }

    let cursor = 0;
    for (const amount of amounts) {
      const before = piece.text.slice(cursor, amount.start);
      const qtyMatch = /(\d{1,3})\s*x\s*$/i.exec(before);
      const quantity = qtyMatch?.[1] ? Math.min(Number(qtyMatch[1]), 999) : 1;
      const segment = piece.text.slice(cursor, amount.end);
      const cuts: Array<[number, number]> = [[amount.start - cursor, amount.end - cursor]];
      if (qtyMatch) cuts.push([before.length - qtyMatch[0].length, before.length]);
      cuts.push(...removalsFor(cursor, amount.end));
      let description = cleanDescription(segment, cuts);
      if (carry) {
        description = description ? `${carry} ${description}` : carry;
        carry = "";
      }
      lines.push({ description, amount: amount.value * quantity, quantity });
      cursor = amount.end;
    }
    const tail = cleanDescription(piece.text.slice(cursor), removalsFor(cursor, piece.text.length));
    if (tail) {
      const last = lines[lines.length - 1];
      if (last) last.description = last.description ? `${last.description} ${tail}` : tail;
    }
  }

  if (carry) {
    const last = lines[lines.length - 1];
    if (last) last.description = last.description ? `${last.description} ${carry}` : carry;
  }
  if (lines.length === 0) return null;
  for (const line of lines) {
    line.description = line.description.replace(/\s+/g, " ").trim();
    if (!line.description) line.description = payee ? `Pembelian di ${payee}` : "Pengeluaran";
    const firstWord = line.description.split(" ")[0] ?? "";
    if (firstWord === firstWord.toLowerCase()) {
      line.description = line.description.charAt(0).toUpperCase() + line.description.slice(1);
    }
    if (line.description.length > 200) line.description = line.description.slice(0, 200);
  }
  const total = lines.reduce((sum, l) => sum + l.amount, 0);
  return { lines, total, date: date?.date ?? null, payee, entityWord, accountWords };
}

export interface AccountOption {
  id: string;
  name: string;
}

/**
 * The account the sender named, if exactly one fits. Compares the words they used with account names
 * ("gopay" -> "GoPay", "bca" -> "BCA Operasional"); two equally good matches mean "ask".
 */
export function matchAccount(
  words: readonly string[],
  accounts: readonly AccountOption[],
): AccountOption | null {
  if (words.length === 0) return null;
  const scored = accounts
    .map((account) => {
      const name = normalizeText(account.name);
      let score = 0;
      for (const w of words) {
        if (containsWord(account.name, w)) score += 10 + w.length;
        else if (
          (w === "tunai" || w === "cash" || w === "kas") &&
          /\b(?:kas|tunai|cash)\b/.test(name)
        )
          score += 8;
        else if (
          (w === "transfer" || w === "debit" || w === "rekening" || w === "tabungan") &&
          /\b(?:bank|bca|bni|bri|mandiri|cimb|rekening)\b/.test(name)
        )
          score += 2;
        else if (
          (w === "ewallet" || w === "e-wallet") &&
          /\b(?:dana|gopay|ovo|shopeepay|linkaja)\b/.test(name)
        )
          score += 4;
      }
      return { account, score };
    })
    .filter((s) => s.score > 0)
    .sort((a, b) => b.score - a.score);
  const [best, second] = scored;
  if (!best) return null;
  if (second && second.score === best.score) return null;
  return best.account;
}

/**
 * Loan instalments (cicilan, angsuran) reduce a loan balance and split into principal and interest, so they are
 * recorded in the loan module on the website, never as a plain expense (decision 422).
 */
export function looksLikeLoanPayment(text: string): boolean {
  return /\b(?:cicilan|angsuran|kpr|bayar\s+pinjaman|bayar\s+hutang|bayar\s+utang|pelunasan|loan\s+(?:payment|instal+ment)|instal+ment|pay\s+(?:the\s+|my\s+)?loan)\b/i.test(
    text,
  );
}
