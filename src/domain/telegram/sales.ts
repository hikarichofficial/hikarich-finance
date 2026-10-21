import { extractExpenseCode } from "./attach";
import { formatDateId } from "./dates";
import { formatDateEn, L, type Lang } from "./i18n";
import { entityWordOf, type EntityWord } from "./message";
import { escapeHtml } from "./report";
import { formatRupiah, parseAmounts } from "./rupiah";
import {
  currentStep,
  needsTyping,
  startVerification,
  stepPrompt,
  type Verification,
} from "./verify";
import type { Keyboard } from "./roadmap";

/**
 * Sales through the bot (decision 425): a new customer, an invoice, the payment of an invoice, and looking an invoice up.
 * Everything here is pure: reading the owner's sentence, holding the state of the conversation, and writing what the bot
 * says. The database calls and the verification answers are in services/telegram/sales.ts and domain/telegram/verify.ts.
 */

export type SalesIntent =
  | {
      kind: "invoice";
      customer: string;
      amount: number | null;
      description: string;
      dueDays: number;
      entityWord: EntityWord | null;
    }
  | {
      kind: "payment";
      number: string;
      amount: number | null;
      accountWords: string[];
      entityWord: EntityWord | null;
    }
  | { kind: "status"; number: string }
  | {
      kind: "customer";
      name: string;
      email: string | null;
      phone: string | null;
      entityWord: EntityWord | null;
    };

const INVOICE_START =
  /^\s*(?:(?:tolong\s+)?(?:buat(?:kan)?|bikin(?:kan)?|terbitkan|create|issue|make|new)\s+)?(?:invoice|faktur)\b\s*/i;
const PAYMENT_START =
  /^\s*(?:(?:sudah\s+)?(?:terima|diterima)|catat\s+pembayaran|pembayaran|lunas|received|payment\s+received|record\s+payment|bayar(?:an)?\s+masuk|paid)\b/i;
const STATUS_START =
  /^\s*(?:status|cek|check|link|tautan|lihat|kirim\s+link|send\s+link|where\s+is)\b/i;
const CUSTOMER_START =
  /^\s*(?:(?:tolong\s+)?(?:tambah(?:kan)?|buat(?:kan)?|bikin(?:kan)?|daftarkan|new|add|create)\s+)?(?:pelanggan|customer|klien|client)\s+(?:baru\s+|new\s+)?/i;
const EMAIL = /[\w.+-]+@[\w-]+(?:\.[\w-]+)+/;
const PHONE = /(?<![\w.])\+?\d[\d\s-]{7,16}\d(?![\w])/;
const DUE =
  /\b(?:jatuh\s+tempo|tempo|due(?:\s+in)?|net)\s*(\d{1,3})\s*(?:hari|days?|d)?\b/i;
const FILLER = /\b(?:untuk|ke|kepada|buat|for|to|atas\s+nama|a\/n)\b/i;
const ENTITY_WORDS = /\b(?:pt|pribadi|personal|perusahaan|company|kantor)\b/gi;

function titleCase(value: string): string {
  if (value !== value.toLowerCase()) return value;
  return value.replace(/\b[a-z]/g, (c) => c.toUpperCase());
}

function tidy(value: string): string {
  return value.replace(/\s+/g, " ").replace(/^[\s,.;:-]+|[\s,.;:-]+$/g, "");
}

/** The amount the owner means: the first one written with a unit or "Rp", else the last number. */
function pickAmount(text: string): { value: number; start: number; end: number } | null {
  const all = parseAmounts(text);
  const chosen = all.find((a) => a.explicit) ?? all[all.length - 1];
  return chosen ? { value: chosen.value, start: chosen.start, end: chosen.end } : null;
}

/** Reads a sales sentence, or returns null when the text is not one. Only explicit opening words count. */
export function parseSalesIntent(raw: string): SalesIntent | null {
  const text = raw.trim();
  if (text.length < 5 || text.startsWith("/")) return null;
  const entityWord = entityWordOf(text);
  const code = extractExpenseCode(text);

  if (STATUS_START.test(text) && code) return { kind: "status", number: code };

  if (PAYMENT_START.test(text) && code) {
    const rest = text.replace(code, " ").replace(/\b(?:rp\.?)\s*/gi, "Rp ");
    const amount = pickAmount(rest);
    const accountWords = rest
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((w) => w.length >= 3);
    return { kind: "payment", number: code, amount: amount?.value ?? null, accountWords, entityWord };
  }

  const customerHead = CUSTOMER_START.exec(text);
  if (customerHead) {
    let rest = text.slice(customerHead[0].length);
    const email = EMAIL.exec(rest)?.[0] ?? null;
    if (email) rest = rest.replace(email, " ");
    const phone = PHONE.exec(rest)?.[0]?.trim() ?? null;
    if (phone) rest = rest.replace(phone, " ");
    const name = tidy(rest.replace(ENTITY_WORDS, " "));
    if (name.length < 2 || name.length > 120) return null;
    return { kind: "customer", name: titleCase(name), email, phone, entityWord };
  }

  const invoiceHead = INVOICE_START.exec(text);
  if (invoiceHead) {
    let rest = text.slice(invoiceHead[0].length);
    const due = DUE.exec(rest);
    if (due) rest = rest.replace(due[0], " ");
    const dueDays = due?.[1] ? Number(due[1]) : 0;
    rest = rest.replace(FILLER, " ").trim();
    const amount = pickAmount(rest);
    const before = amount ? rest.slice(0, amount.start) : rest;
    const after = amount ? rest.slice(amount.end) : "";
    const customer = tidy(before.replace(ENTITY_WORDS, " ").replace(/\b(?:sebesar|senilai|total|rp\.?)\s*$/i, ""));
    if (customer.length < 2) return null;
    const description = tidy(after.replace(ENTITY_WORDS, " ").replace(/^\s*(?:untuk|buat|for|:)\s+/i, ""));
    return {
      kind: "invoice",
      customer: titleCase(customer).slice(0, 120),
      amount: amount?.value ?? null,
      description: description.slice(0, 200),
      dueDays,
      entityWord,
    };
  }
  return null;
}

// ---- the conversation state -------------------------------------------------------------------------------------

export interface Candidate {
  id: string;
  name: string;
  email: string | null;
  severity: "same_name" | "like";
}
export interface EntityChoice {
  id: string;
  name: string;
  type: string;
}
export interface ChannelChoice {
  id: string;
  name: string;
  accountId: string | null;
}
export interface AccountChoice {
  id: string;
  name: string;
}
export interface InvoiceRef {
  invoiceId: string;
  entityId: string;
  entityName: string;
  number: string;
  customerName: string;
  currency: string;
  total: number;
  outstanding: number;
}

export type SalesPhase =
  | "entity"
  | "describe"
  | "dup"
  | "channel"
  | "invoice"
  | "account"
  | "verify";

export interface SalesOp {
  v: 2;
  nonce: string;
  /** Base of the idempotency keys: one conversation, one customer, one invoice, one payment. */
  key: string;
  messageId: number | null;
  lang: Lang;
  kind: "invoice" | "payment" | "customer";
  phase: SalesPhase;
  today: string;
  entities: EntityChoice[];
  entityId: string | null;
  entityName: string;
  customerName: string;
  email: string | null;
  phone: string | null;
  customerId: string | null;
  allowSimilar: boolean;
  candidates: Candidate[];
  description: string;
  amount: number;
  dueDays: number;
  channels: ChannelChoice[];
  channelId: string | null;
  channelName: string | null;
  accountId: string | null;
  accountName: string | null;
  accounts: AccountChoice[];
  accountWords: string[];
  invoice: InvoiceRef | null;
  choices: InvoiceRef[];
  verification: Verification | null;
}

export function newOp(opts: {
  kind: SalesOp["kind"];
  nonce: string;
  key: string;
  lang: Lang;
  today: string;
  entities: EntityChoice[];
}): SalesOp {
  return {
    v: 2,
    nonce: opts.nonce,
    key: opts.key,
    messageId: null,
    lang: opts.lang,
    kind: opts.kind,
    phase: "entity",
    today: opts.today,
    entities: opts.entities,
    entityId: null,
    entityName: "",
    customerName: "",
    email: null,
    phone: null,
    customerId: null,
    allowSimilar: false,
    candidates: [],
    description: "",
    amount: 0,
    dueDays: 0,
    channels: [],
    channelId: null,
    channelName: null,
    accountId: null,
    accountName: null,
    accounts: [],
    accountWords: [],
    invoice: null,
    choices: [],
    verification: null,
  };
}

/** The money figure the owner must retype: only an invoice or a payment has one. */
export function totalOf(op: SalesOp): number {
  return op.kind === "customer" ? 0 : op.kind === "invoice" ? op.amount : op.amount;
}

export function verifyLevel(op: SalesOp): "master" | "money" {
  return op.kind === "customer" ? "master" : "money";
}

export function beginVerification(op: SalesOp): SalesOp {
  return { ...op, phase: "verify", verification: startVerification(verifyLevel(op)) };
}

// ---- reading typed answers --------------------------------------------------------------------------------------

export type DupAnswer = { kind: "use"; index: number } | { kind: "new" } | { kind: "unclear" };

/** "1", "pakai yang lama", "buat baru"... Several candidates need a number to pick one. */
export function readDupAnswer(text: string, candidates: number): DupAnswer {
  const t = text.toLowerCase().trim();
  if (/\b(?:baru|new|lain|berbeda|different|another)\b/.test(t)) return { kind: "new" };
  const n = /^\s*#?(\d{1,2})\s*$/.exec(t) ?? /\b(?:no(?:mor)?|nomor|number|#)\s*(\d{1,2})\b/.exec(t);
  if (n?.[1]) {
    const index = Number(n[1]) - 1;
    return index >= 0 && index < candidates ? { kind: "use", index } : { kind: "unclear" };
  }
  if (/\b(?:pakai|pake|gunakan|use|lama|itu|existing|yang\s+ada|sama)\b/.test(t) && candidates === 1)
    return { kind: "use", index: 0 };
  return { kind: "unclear" };
}

/** "pt" / "pribadi" / a number, for the entity and similar single-choice questions. */
export function readChoice(text: string, labels: readonly string[]): number | null {
  const t = text.toLowerCase().trim();
  const n = /^\s*#?(\d{1,2})\s*$/.exec(t);
  if (n?.[1]) {
    const i = Number(n[1]) - 1;
    return i >= 0 && i < labels.length ? i : null;
  }
  const hits = labels
    .map((label, i) => ({ i, label: label.toLowerCase() }))
    .filter((x) => x.label.length >= 2 && (t.includes(x.label) || x.label.includes(t)) && t.length >= 2);
  return hits.length === 1 ? (hits[0]?.i ?? null) : null;
}

// ---- what the bot says ------------------------------------------------------------------------------------------

function dateOf(lang: Lang, iso: string): string {
  return lang === "en" ? formatDateEn(iso) : formatDateId(iso);
}

function addDays(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function dueDateOf(op: SalesOp): string {
  return addDays(op.today, op.dueDays);
}

const SETTLEMENT: Record<string, { id: string; en: string }> = {
  unpaid: { id: "Belum dibayar", en: "Unpaid" },
  partial: { id: "Dibayar sebagian", en: "Partly paid" },
  paid: { id: "Lunas (dibayar)", en: "Paid in full" },
};

export function settlementLabel(status: string | null | undefined, lang: Lang): string {
  const entry = status ? SETTLEMENT[status] : undefined;
  return entry ? (lang === "en" ? entry.en : entry.id) : "-";
}

function button(op: SalesOp, text: string, action: string, arg = "") {
  return { text, data: `o|${action}|${op.nonce}${arg ? `:${arg}` : ""}` };
}

export function summaryOf(op: SalesOp): string {
  const lang = op.lang;
  const e = escapeHtml(op.entityName);
  if (op.kind === "customer") {
    return [
      `👤 <b>${L(lang, "Pelanggan baru", "New customer")}</b> — ${e}`,
      `${L(lang, "Nama", "Name")}: <b>${escapeHtml(op.customerName)}</b>`,
      op.email ? `Email: ${escapeHtml(op.email)}` : null,
      op.phone ? `${L(lang, "Telepon", "Phone")}: ${escapeHtml(op.phone)}` : null,
      op.allowSimilar
        ? L(lang, "Nama sama dengan pelanggan lain, dibuat sebagai orang yang berbeda.", "Same name as another customer, created as a different person.")
        : null,
    ]
      .filter(Boolean)
      .join("\n");
  }
  if (op.kind === "invoice") {
    const customer = op.customerId
      ? `${escapeHtml(op.customerName)} (${L(lang, "terdaftar", "existing")})`
      : `${escapeHtml(op.customerName)} (${L(lang, "pelanggan baru, dibuat bersamaan", "new customer, created together")})`;
    return [
      `🧾 <b>${L(lang, "Invoice baru", "New invoice")}</b> — ${e}`,
      `${L(lang, "Pelanggan", "Customer")}: ${customer}`,
      `${L(lang, "Barang/jasa", "Item")}: ${escapeHtml(op.description)}`,
      `${L(lang, "Total", "Total")}: <b>${formatRupiah(op.amount)}</b>`,
      `${L(lang, "Terbit", "Issued")}: ${dateOf(lang, op.today)} · ${L(lang, "Jatuh tempo", "Due")}: ${dateOf(lang, dueDateOf(op))}`,
      `${L(lang, "Tautan pembayaran", "Payment link")}: ${op.channelName ? escapeHtml(op.channelName) : L(lang, "tidak ada", "none")}`,
    ].join("\n");
  }
  const inv = op.invoice;
  if (!inv) return "";
  const after = inv.outstanding - op.amount;
  const status = after <= 0 ? "paid" : "partial";
  return [
    `💰 <b>${L(lang, "Catat pembayaran", "Record payment")}</b> — ${escapeHtml(inv.entityName)}`,
    `Invoice <b>${escapeHtml(inv.number)}</b> — ${escapeHtml(inv.customerName)}`,
    `${L(lang, "Dibayar", "Paid")}: <b>${formatRupiah(op.amount)}</b> ${L(lang, "dari sisa", "of the remaining")} ${formatRupiah(inv.outstanding)}`,
    `${L(lang, "Status sesudahnya", "Status afterwards")}: ${settlementLabel(status, lang)}${after > 0 ? ` (${L(lang, "sisa", "left")} ${formatRupiah(after)})` : ""}`,
    `${L(lang, "Diterima di", "Received in")}: ${escapeHtml(op.accountName ?? "-")} · ${dateOf(lang, op.today)}`,
  ].join("\n");
}

/** The message and buttons for the phase the conversation is in. */
export function renderOp(op: SalesOp): { text: string; keyboard: Keyboard } {
  const lang = op.lang;
  const cancel = button(op, L(lang, "❌ Batal", "❌ Cancel"), "no");
  switch (op.phase) {
    case "entity":
      return {
        text: L(lang, "Untuk entitas yang mana?", "Which entity is this for?"),
        keyboard: {
          rows: [
            ...op.entities.map((x, i) => [
              button(op, `${x.type === "personal" ? "👤" : "🏢"} ${x.name}`, "ent", String(i)),
            ]),
            [cancel],
          ],
        },
      };
    case "describe":
      return {
        text: L(
          lang,
          "Invoice ini untuk apa? Ketik nama barang atau jasanya (contoh: Jasa konsultasi Oktober).",
          "What is this invoice for? Type the item or service (e.g. Consulting October).",
        ),
        keyboard: { rows: [[cancel]] },
      };
    case "dup": {
      const same = op.candidates.some((c) => c.severity === "same_name");
      const head = same
        ? L(
            lang,
            `⚠️ Nama <b>${escapeHtml(op.customerName)}</b> sudah terdaftar. Pakai pelanggan yang itu, atau buat baru dengan nama yang sama?`,
            `⚠️ The name <b>${escapeHtml(op.customerName)}</b> is already registered. Use that customer, or create a new one with the same name?`,
          )
        : L(
            lang,
            `Ada pelanggan dengan nama mirip <b>${escapeHtml(op.customerName)}</b>. Pakai salah satu, atau buat baru?`,
            `There are customers with a similar name to <b>${escapeHtml(op.customerName)}</b>. Use one of them, or create a new one?`,
          );
      const list = op.candidates
        .map((c, i) => `${i + 1}. ${escapeHtml(c.name)}${c.email ? ` (${escapeHtml(c.email)})` : ""}`)
        .join("\n");
      return {
        text: `${head}\n\n${list}\n\n${L(lang, "Balas dengan tombol, atau ketik: nomor, <i>pakai yang lama</i>, atau <i>buat baru</i>.", "Answer with a button, or type: a number, <i>use the existing one</i>, or <i>create new</i>.")}`,
        keyboard: {
          rows: [
            ...op.candidates.map((c, i) => [
              button(op, `${L(lang, "Pakai", "Use")} #${i + 1} ${c.name}`.slice(0, 60), "use", String(i)),
            ]),
            [button(op, L(lang, "➕ Buat baru (nama sama)", "➕ Create new (same name)"), "new")],
            [cancel],
          ],
        },
      };
    }
    case "channel":
      return {
        text: L(
          lang,
          "Pakai tautan pembayaran yang mana untuk invoice ini?",
          "Which payment link should this invoice carry?",
        ),
        keyboard: {
          rows: [
            ...op.channels.map((c, i) => [button(op, c.name.slice(0, 60), "chan", String(i))]),
            [button(op, L(lang, "Tanpa tautan pembayaran", "No payment link"), "chan", "-")],
            [cancel],
          ],
        },
      };
    case "invoice":
      return {
        text: L(
          lang,
          "Nomor itu ada di lebih dari satu entitas. Yang mana?",
          "That number exists in more than one entity. Which one?",
        ),
        keyboard: {
          rows: [
            ...op.choices.map((c, i) => [button(op, `${c.entityName} — ${c.customerName}`.slice(0, 60), "inv", String(i))]),
            [cancel],
          ],
        },
      };
    case "account":
      return {
        text: L(lang, "Pembayaran diterima di rekening mana?", "Which account received the payment?"),
        keyboard: {
          rows: [
            ...op.accounts.map((a, i) => [button(op, a.name.slice(0, 60), "acc", String(i))]),
            [cancel],
          ],
        },
      };
    case "verify": {
      const v = op.verification;
      if (!v) return { text: summaryOf(op), keyboard: { rows: [[cancel]] } };
      const body = `${summaryOf(op)}\n\n${stepPrompt(v, formatRupiah(totalOf(op)), lang)}`;
      const step = currentStep(v);
      const go =
        step === "final"
          ? L(lang, "✅ Ya, simpan", "✅ Yes, save")
          : L(lang, "➡️ Lanjut", "➡️ Continue");
      return {
        text: body,
        keyboard: { rows: [needsTyping(v) ? [cancel] : [button(op, go, "go"), cancel]] },
      };
    }
  }
}

/** Parses the argument of a sales button: `<nonce>[:<value>]`. */
export function parseOpArg(arg: string): { nonce: string; value: string } {
  const [nonce = "", ...rest] = arg.split(":");
  return { nonce, value: rest.join(":") };
}

export function invoiceLink(appUrl: string, token: string): string {
  return `${appUrl.replace(/\/+$/, "")}/i/${token}`;
}

export function receiptLink(appUrl: string, token: string, receiptNumber: string): string {
  return `${invoiceLink(appUrl, token)}/receipt?no=${encodeURIComponent(receiptNumber)}`;
}
