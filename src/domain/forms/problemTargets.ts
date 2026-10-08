/**
 * Which field a refusal is about (OWNER, 8 October 2026: "error atau penolakan simpan/submit harus jelas, mana
 * yang harus diubah ... diberikan aksen berwarna merah"). The database refuses with an English reason that names
 * the line ("Line 2 has no withholding classification ...") and the screens translate it; this module reads the
 * same reason and says WHICH line and column (or form field) to mark red, so the person sees where to change.
 *
 * Display only: it decides nothing and a reason it does not recognise simply marks nothing (the translated
 * message is still shown). Line numbers are the database's 1-based positions among the lines that were sent.
 */
export type LineField =
  "description" | "amount" | "category" | "treatment" | "wht" | "vat_invoice_ref" | "vat_amount";

export type FormField = "account" | "date" | "due" | "payee" | "receipt" | "lines";

export type ProblemTarget =
  { scope: "line"; line: number; field: LineField } | { scope: "form"; field: FormField };

export const LINE_FIELD_LABELS: Record<LineField, string> = {
  description: "Deskripsi",
  amount: "Jumlah",
  category: "Kategori",
  treatment: "Perlakuan",
  wht: "Kena potongan PPh?",
  vat_invoice_ref: "No. Faktur Pajak",
  vat_amount: "PPN ditagih vendor",
};

export const FORM_FIELD_LABELS: Record<FormField, string> = {
  account: "Rekening",
  date: "Tanggal",
  due: "Jatuh Tempo",
  payee: "Vendor / Nama Penerima",
  receipt: "Nomor Struk",
  lines: "Baris",
};

/** What to do in each field, shown under it in red. */
export const LINE_FIELD_HINTS: Record<LineField, string> = {
  description: "Isi deskripsi baris ini.",
  amount: "Isi jumlah yang benar (lebih dari nol).",
  category: "Pilih kategori yang sesuai.",
  treatment: "Pilih perlakuan yang sesuai.",
  wht: "Pilih jawaban di sini.",
  vat_invoice_ref: "Isi nomor faktur pajak dari vendor.",
  vat_amount: "Periksa jumlah PPN (tidak boleh minus).",
};

export const FORM_FIELD_HINTS: Record<FormField, string> = {
  account: "Pilih rekening pembayaran.",
  date: "Periksa tanggalnya.",
  due: "Jatuh tempo tidak boleh sebelum tanggal tagihan.",
  payee: "Pilih vendor atau isi nama penerima.",
  receipt: "Periksa nomor struk (maksimal 100 huruf).",
  lines: "Isi minimal satu baris dengan deskripsi dan jumlah.",
};

type LinePattern = [RegExp, LineField];

// Each pattern captures the line number first. Matched with the `i` flag on the English reason.
const LINE_PATTERNS: LinePattern[] = [
  [/line (\d+) needs a description/gi, "description"],
  [
    /line (\d+) (?:amount|has an amount|needs a non-zero amount|needs a unit price|unit price|quantity|original amount|has more decimals|base amount|has a date or amount)/gi,
    "amount",
  ],
  [/line (\d+) (?:category|has no usable|account|product)/gi, "category"],
  [/line (\d+) treatment/gi, "treatment"],
  [
    /line (\d+) (?:has an unknown withholding|has no withholding classification|is marked "not sure"|\([^)]*\) is paid to an individual)/gi,
    "wht",
  ],
  [/no single withholding rule covers line (\d+)/gi, "wht"],
  [/line (\d+) (?:carries VAT but no tax-invoice|tax-invoice reference)/gi, "vat_invoice_ref"],
  [/line (\d+) VAT amount/gi, "vat_amount"],
];

type FormPattern = [RegExp, FormField];

const FORM_PATTERNS: FormPattern[] = [
  [
    /name (?:a|the) vendor or (?:a|the) payee|payee is unknown|payee is limited to 200|inactive contact|the payee is not a contact|payee is not recorded|payee needs/i,
    "payee",
  ],
  [/(?:expense|bill) date is required|dated in the future/i, "date"],
  [/due date/i, "due"],
  [/receipt reference to 100/i, "receipt"],
  [/payment account is unknown|paying account/i, "account"],
  [/needs at least one line/i, "lines"],
];

/** Every field the (English) reason is about, without duplicates, in the order they appear. */
export function locateProblems(reason: string): ProblemTarget[] {
  const found: ProblemTarget[] = [];
  const seen = new Set<string>();
  const add = (target: ProblemTarget) => {
    const key = encodeProblem(target);
    if (seen.has(key)) return;
    seen.add(key);
    found.push(target);
  };
  for (const [pattern, field] of LINE_PATTERNS) {
    for (const match of reason.matchAll(pattern)) {
      add({ scope: "line", line: Number(match[1]), field });
    }
  }
  for (const [pattern, field] of FORM_PATTERNS) {
    if (pattern.test(reason)) add({ scope: "form", field });
  }
  return found.sort(
    (a, b) =>
      (a.scope === "line" ? a.line : 0) - (b.scope === "line" ? b.line : 0) ||
      (a.scope === b.scope ? 0 : a.scope === "form" ? -1 : 1),
  );
}

/** Short text for a link: `l2.wht`, `f.payee`. */
export function encodeProblem(target: ProblemTarget): string {
  return target.scope === "line" ? `l${target.line}.${target.field}` : `f.${target.field}`;
}

export function encodeProblems(targets: readonly ProblemTarget[]): string {
  return targets.map(encodeProblem).join(",");
}

export function decodeProblems(text: string | undefined | null): ProblemTarget[] {
  if (!text) return [];
  const result: ProblemTarget[] = [];
  for (const part of text.split(",").slice(0, 40)) {
    const line = /^l(\d{1,3})\.([a-z_]+)$/.exec(part);
    if (line && line[2] && line[2] in LINE_FIELD_LABELS) {
      result.push({ scope: "line", line: Number(line[1]), field: line[2] as LineField });
      continue;
    }
    const form = /^f\.([a-z_]+)$/.exec(part);
    if (form && form[1] && form[1] in FORM_FIELD_LABELS) {
      result.push({ scope: "form", field: form[1] as FormField });
    }
  }
  return result;
}

/** "Baris 2 · Kena potongan PPh?" -- one entry per target, for the sentence under the error. */
export function describeProblems(targets: readonly ProblemTarget[]): string[] {
  return targets.map((target) =>
    target.scope === "line"
      ? `Baris ${target.line} · ${LINE_FIELD_LABELS[target.field]}`
      : FORM_FIELD_LABELS[target.field],
  );
}
