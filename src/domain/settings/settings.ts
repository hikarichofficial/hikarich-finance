import type { NumberingScope, NumberingSequenceRow } from "@/schemas/settings";

/**
 * Pure helpers for the read-only Settings screen (P13 unbuilt-screens backlog, decision 243). Labels and
 * display formatting only; nothing here is authoritative and nothing calls the database.
 */

export const ENTITY_TYPE_LABELS: Readonly<Record<"company" | "personal" | "other", string>> = {
  company: "Perusahaan",
  personal: "Pribadi",
  other: "Lainnya",
};

export const NUMBERING_SCOPE_LABELS: Readonly<Record<NumberingScope, string>> = {
  invoice: "Invoice Penjualan",
  payment_receipt: "Kuitansi Pembayaran",
  refund_receipt: "Kuitansi Refund",
  bill: "Tagihan Pembelian",
  journal: "Jurnal",
  other: "Lainnya",
};

export const RESET_POLICY_LABELS: Readonly<Record<"yearly" | "never", string>> = {
  yearly: "Setiap tahun",
  never: "Tidak pernah",
};

const MONTH_NAMES = [
  "Januari",
  "Februari",
  "Maret",
  "April",
  "Mei",
  "Juni",
  "Juli",
  "Agustus",
  "September",
  "Oktober",
  "November",
  "Desember",
] as const;

/** 1-12 to its Indonesian month name (`fiscal_year_start_month` is checked 1-12 by the database). */
export function monthName(month: number): string {
  return MONTH_NAMES[month - 1] ?? String(month);
}

/** Example of the first number a sequence would issue in `year`, built exactly the way
 * `app_private.allocate_document_number` (P1) builds it: prefix, separator, optional year and separator,
 * then the counter left-padded with zeros. Postgres `lpad` truncates a longer value to the padding width;
 * the counter here is always 1, which never exceeds any padding the database allows (1-10). */
export function numberingExample(
  sequence: Pick<NumberingSequenceRow, "prefix" | "separator" | "include_year" | "padding">,
  year: number,
): string {
  const yearPart = sequence.include_year ? `${year}${sequence.separator}` : "";
  return `${sequence.prefix}${sequence.separator}${yearPart}${"1".padStart(sequence.padding, "0")}`;
}

/** The three `entity_settings` keys the database reads today, with a readable label. Any other key is
 * still shown, under its raw key, so nothing stored is hidden. */
export const ENTITY_SETTING_LABELS: Readonly<Record<string, string>> = {
  "money.block_negative_balance": "Tolak transaksi yang membuat saldo kas/bank negatif",
  "money.match_date_tolerance_days": "Toleransi selisih tanggal saat mencocokkan mutasi (hari)",
  "security.require_mfa": "Wajibkan autentikasi dua faktor (MFA)",
};

export function entitySettingLabel(key: string): string {
  return Object.hasOwn(ENTITY_SETTING_LABELS, key) ? ENTITY_SETTING_LABELS[key] : key;
}

/** A stored JSON value as display text: booleans as Ya/Tidak, everything else as compact JSON. */
export function entitySettingValueText(value: unknown): string {
  if (value === true) return "Ya";
  if (value === false) return "Tidak";
  if (typeof value === "string") return value;
  if (typeof value === "number") return String(value);
  return JSON.stringify(value) ?? "—";
}

/** Indonesia's three time zones (decision 248). Any other valid IANA zone already stored is still shown
 * and kept; these are the choices offered. */
export const INDONESIA_TIMEZONES: ReadonlyArray<{ value: string; label: string }> = [
  { value: "Asia/Jakarta", label: "WIB (UTC+7) — Asia/Jakarta" },
  { value: "Asia/Makassar", label: "WITA (UTC+8) — Asia/Makassar" },
  { value: "Asia/Jayapura", label: "WIT (UTC+9) — Asia/Jayapura" },
];

/** The timezone choices for the form: the Indonesian zones, plus the stored one when it is another. */
export function timezoneOptions(current: string): ReadonlyArray<{ value: string; label: string }> {
  return INDONESIA_TIMEZONES.some((z) => z.value === current)
    ? INDONESIA_TIMEZONES
    : [...INDONESIA_TIMEZONES, { value: current, label: current }];
}

export function timezoneLabel(value: string): string {
  return INDONESIA_TIMEZONES.find((z) => z.value === value)?.label ?? value;
}

/** A conflict message from `update_entity_time_settings` that names the fiscal-year lock. */
export function isFiscalYearLockedMessage(message: string | null | undefined): boolean {
  return !!message && message.includes("fiscal year start cannot change");
}
