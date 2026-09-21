import { Decimal } from "@/domain/money/decimal";

/**
 * Vocabulary and exact arithmetic that screens use for early feedback on the tax layer (P7). This module holds
 * NO tax rule: rates, effective dates, formulas, exemptions, deadlines and thresholds live in the database's
 * versioned rule master and are applied there (Step 05, Step 15 §11, Step 16 §15). What is here is only what a
 * screen needs to label a result, check the shape of an input before sending it, and show money exactly.
 */

// ---- vocabulary
export type TaxType = "vat" | "wht_pph23" | "final_umkm";
export type TaxKind = "vat_output" | "vat_input" | "wht_pph23" | "final_umkm";
export type TaxDirection = "payable" | "asset";

export const TAX_TYPE_LABELS: Readonly<Record<TaxType, string>> = {
  vat: "PPN",
  wht_pph23: "PPh 23 (dipotong)",
  final_umkm: "PPh Final UMKM",
};

export const TAX_KIND_LABELS: Readonly<Record<TaxKind, string>> = {
  vat_output: "PPN keluaran",
  vat_input: "PPN masukan",
  wht_pph23: "PPh 23 dipotong",
  final_umkm: "PPh Final UMKM",
};

/** How firmly a tax result stands (Step 05 §14). `needs_review` blocks recognition until a person decides. */
export type DeterminationStatus =
  | "auto_determined"
  | "owner_confirmed"
  | "overridden"
  | "needs_review"
  | "not_configured"
  | "not_applicable"
  | "superseded";

export const DETERMINATION_STATUS_LABELS: Readonly<Record<DeterminationStatus, string>> = {
  auto_determined: "Ditentukan otomatis",
  owner_confirmed: "Dikonfirmasi",
  overridden: "Diubah pemilik",
  needs_review: "Perlu ditinjau",
  not_configured: "Belum aktif",
  not_applicable: "Tidak berlaku",
  superseded: "Digantikan",
};

/** A document that still needs a person's decision must not be recognised. */
export function blocksRecognition(status: DeterminationStatus): boolean {
  return status === "needs_review";
}

export type CalendarStep = "calculate" | "pay" | "file" | "evidence";
export type CalendarState = "done" | "due" | "overdue" | "upcoming" | "not_applicable" | "no_rule";

export const CALENDAR_STEP_LABELS: Readonly<Record<CalendarStep, string>> = {
  calculate: "Hitung",
  pay: "Bayar",
  file: "Lapor",
  evidence: "Bukti",
};

export const CALENDAR_STATE_LABELS: Readonly<Record<CalendarState, string>> = {
  done: "Selesai",
  due: "Perlu dikerjakan",
  overdue: "Terlambat",
  upcoming: "Akan datang",
  not_applicable: "Tidak berlaku",
  no_rule: "Belum ada aturan",
};

/** Differences the reconciliation of a tax period can show (Step 05, Step 12). */
export type DifferenceCode =
  | "filing_missing"
  | "filed_tax_differs"
  | "filed_credit_differs"
  | "filed_base_differs"
  | "unpaid"
  | "overpaid";

export const DIFFERENCE_LABELS: Readonly<Record<DifferenceCode, string>> = {
  filing_missing: "Belum ada pelaporan",
  filed_tax_differs: "Pajak yang dilaporkan berbeda dari buku",
  filed_credit_differs: "Kredit PPN yang dilaporkan berbeda dari buku",
  filed_base_differs: "Dasar pengenaan yang dilaporkan berbeda dari buku",
  unpaid: "Belum dibayar",
  overpaid: "Kelebihan bayar",
};

export type EvidencePurpose =
  "filing_receipt" | "payment_proof" | "withholding_slip" | "tax_invoice" | "other";

export const EVIDENCE_PURPOSE_LABELS: Readonly<Record<EvidencePurpose, string>> = {
  filing_receipt: "Bukti lapor",
  payment_proof: "Bukti bayar",
  withholding_slip: "Bukti potong",
  tax_invoice: "Faktur pajak",
  other: "Lainnya",
};

// ---- periods
const MONTHS_ID = [
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

const ISO_DATE = /^(\d{4})-(\d{2})-(\d{2})$/;

/** The first day of the month of an ISO date: a tax period is always identified by it. */
export function taxPeriodStart(isoDate: string): string {
  const m = ISO_DATE.exec(isoDate);
  if (!m) throw new RangeError("Not an ISO date");
  return `${m[1]}-${m[2]}-01`;
}

export function isTaxPeriodStart(isoDate: string): boolean {
  const m = ISO_DATE.exec(isoDate);
  return m !== null && m[3] === "01";
}

/** "September 2026" for 2026-09-01. */
export function taxPeriodLabel(period: string): string {
  const m = ISO_DATE.exec(period);
  if (!m) throw new RangeError("Not an ISO date");
  const month = Number(m[2]);
  if (month < 1 || month > 12) throw new RangeError("Not an ISO date");
  return `${MONTHS_ID[month - 1]} ${m[1]}`;
}

// ---- payment arithmetic (early feedback only; the database recomputes and enforces everything)
export interface TaxPaymentParts {
  /** Tax paid against the liability of the period. */
  payable: string;
  /** Input VAT used to settle part of a VAT payment. */
  assetOffset?: string;
  /** A late-payment penalty, booked as its own expense. */
  penalty?: string;
}

/** The cash that leaves the account: tax paid, less input VAT offset, plus any penalty. */
export function taxPaymentCash(parts: TaxPaymentParts): Decimal {
  const payable = Decimal.tryParse(parts.payable);
  const offset = Decimal.tryParse(parts.assetOffset ?? "0");
  const penalty = Decimal.tryParse(parts.penalty ?? "0");
  if (!payable || !offset || !penalty) throw new RangeError("Not a decimal amount");
  return payable.sub(offset).add(penalty);
}

export type PaymentIssue =
  | "payable_not_positive"
  | "negative_amount"
  | "offset_only_vat"
  | "offset_exceeds_payable"
  | "penalty_needs_note"
  | "account_required"
  | "account_not_needed";

export const PAYMENT_ISSUE_LABELS: Readonly<Record<PaymentIssue, string>> = {
  payable_not_positive: "Pajak yang dibayar harus lebih dari nol",
  negative_amount: "Jumlah tidak boleh negatif",
  offset_only_vat: "Hanya PPN yang dapat dikompensasi dengan PPN masukan",
  offset_exceeds_payable: "Kompensasi tidak boleh melebihi PPN yang dibayar",
  penalty_needs_note: "Denda perlu catatan yang menjelaskannya (misalnya nomor surat tagihan)",
  account_required: "Pilih akun pembayaran",
  account_not_needed: "Pembayaran yang seluruhnya dikompensasi tidak memakai akun",
};

/** Shape checks a form can show before submitting; the database re-checks all of them and more. */
export function checkTaxPayment(
  input: TaxPaymentParts & { taxType: TaxType; note?: string; hasAccount: boolean },
): PaymentIssue[] {
  const payable = Decimal.tryParse(input.payable);
  const offset = Decimal.tryParse(input.assetOffset ?? "0");
  const penalty = Decimal.tryParse(input.penalty ?? "0");
  if (!payable || !offset || !penalty) return ["negative_amount"];
  const issues: PaymentIssue[] = [];
  if (payable.isNegative() || offset.isNegative() || penalty.isNegative()) {
    issues.push("negative_amount");
  }
  if (!payable.isPositive()) issues.push("payable_not_positive");
  if (offset.isPositive() && input.taxType !== "vat") issues.push("offset_only_vat");
  if (offset.cmp(payable) > 0) issues.push("offset_exceeds_payable");
  if (penalty.isPositive() && (input.note ?? "").trim().length < 5)
    issues.push("penalty_needs_note");
  const cash = payable.sub(offset).add(penalty);
  if (cash.isPositive() && !input.hasAccount) issues.push("account_required");
  if (!cash.isPositive() && input.hasAccount) issues.push("account_not_needed");
  return issues;
}

/**
 * What is still to pay for a period from its accrued and paid amounts. A negative result is a visible credit
 * (the source was reversed after the tax was paid): it is shown, never hidden or clamped.
 */
export function outstandingTax(accrued: string, paid: string): Decimal {
  const a = Decimal.tryParse(accrued);
  const p = Decimal.tryParse(paid);
  if (!a || !p) throw new RangeError("Not a decimal amount");
  return a.sub(p);
}
