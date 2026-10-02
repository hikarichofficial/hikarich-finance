import { Decimal } from "@/domain/money/decimal";

/**
 * Vocabulary and exact arithmetic that screens use for early feedback on the tax layer (P7). This module holds
 * NO tax rule: rates, effective dates, formulas, exemptions, deadlines and thresholds live in the database's
 * versioned rule master and are applied there (Step 05, Step 15 §11, Step 16 §15). What is here is only what a
 * screen needs to label a result, check the shape of an input before sending it, and show money exactly.
 */

// ---- vocabulary
export type TaxType =
  "vat" | "wht_pph23" | "wht_pph4_2" | "wht_pph26" | "wht_pph21" | "final_umkm";
export type TaxKind =
  | "vat_output"
  | "vat_input"
  | "wht_pph23"
  | "wht_pph4_2"
  | "wht_pph26"
  | "wht_pph21"
  | "final_umkm";
export type TaxDirection = "payable" | "asset";

export const TAX_TYPE_LABELS: Readonly<Record<TaxType, string>> = {
  vat: "PPN",
  wht_pph23: "PPh 23 (dipotong)",
  wht_pph4_2: "PPh 4(2) sewa tanah/bangunan",
  wht_pph26: "PPh 26 (luar negeri)",
  wht_pph21: "PPh 21 (karyawan)",
  final_umkm: "PPh Final UMKM",
};

export const TAX_KIND_LABELS: Readonly<Record<TaxKind, string>> = {
  vat_output: "PPN keluaran",
  vat_input: "PPN masukan",
  wht_pph23: "PPh 23 dipotong",
  wht_pph4_2: "PPh 4(2) dipotong",
  wht_pph26: "PPh 26 dipotong",
  wht_pph21: "PPh 21 karyawan",
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

/** The status badge tone the Tax Ledger and Tax Determination Detail screens (P13 Part 3e) show a status in,
 * matching the tone vocabulary `.status-badge-*` already defines (Bills, Invoices, Accounts). */
export type DeterminationTone = "neutral" | "progress" | "attention" | "success" | "critical";

export const DETERMINATION_STATUS_TONE: Readonly<Record<DeterminationStatus, DeterminationTone>> = {
  auto_determined: "progress",
  owner_confirmed: "success",
  overridden: "attention",
  needs_review: "critical",
  not_configured: "neutral",
  not_applicable: "neutral",
  superseded: "neutral",
};

// ---- the Entity's own tax facts (Step 05 §1-§2's profile), as `tax_overview` returns them
export type TaxpayerKind =
  "individual" | "perseroan_perorangan" | "company" | "cooperative" | "other" | "unknown";

export const TAXPAYER_KIND_LABELS: Readonly<Record<TaxpayerKind, string>> = {
  individual: "Orang pribadi",
  perseroan_perorangan: "Perseroan perorangan",
  company: "Badan usaha",
  cooperative: "Koperasi",
  other: "Lainnya",
  unknown: "Belum diketahui",
};

export function taxpayerKindLabel(kind: TaxpayerKind): string {
  return TAXPAYER_KIND_LABELS[kind];
}

export type TaxResidency = "resident" | "non_resident" | "unknown";

export const TAX_RESIDENCY_LABELS: Readonly<Record<TaxResidency, string>> = {
  resident: "Dalam negeri",
  non_resident: "Luar negeri",
  unknown: "Belum diketahui",
};

export function taxResidencyLabel(residency: TaxResidency): string {
  return TAX_RESIDENCY_LABELS[residency];
}

export type IncomeRegime = "final_umkm" | "general" | "unknown";

export const INCOME_REGIME_LABELS: Readonly<Record<IncomeRegime, string>> = {
  final_umkm: "PPh Final UMKM",
  general: "Umum",
  unknown: "Belum diketahui",
};

export function incomeRegimeLabel(regime: IncomeRegime): string {
  return INCOME_REGIME_LABELS[regime];
}

export type VatStatus = "pkp" | "non_pkp" | "unknown";

export const VAT_STATUS_LABELS: Readonly<Record<VatStatus, string>> = {
  pkp: "Pengusaha Kena Pajak (PKP)",
  non_pkp: "Bukan PKP",
  unknown: "Belum diketahui",
};

export function vatStatusLabel(status: VatStatus): string {
  return VAT_STATUS_LABELS[status];
}

export type YesNoUnknown = "yes" | "no" | "unknown";

export const YES_NO_UNKNOWN_LABELS: Readonly<Record<YesNoUnknown, string>> = {
  yes: "Ya",
  no: "Tidak",
  unknown: "Belum diketahui",
};

export function yesNoUnknownLabel(value: YesNoUnknown): string {
  return YES_NO_UNKNOWN_LABELS[value];
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

const MONTH_INPUT = /^(\d{4})-(\d{2})$/;

/** The period a period-based Tax screen (PPh Final, Withholding, PPN) opens to when no valid `?period=` is
 * given: the most recently completed calendar month, since that is the period most likely to already be
 * ready to compute, pay or file. Accepts a native `<input type="month">`'s own "YYYY-MM" value directly (its
 * GET submission needs no client-side JavaScript to become a period), as well as a full "YYYY-MM-01" period;
 * anything else -- absent, malformed, or a date that is not the 1st -- falls back to the default. */
export function resolveTaxPeriod(
  requested: string | undefined,
  reference: Date = new Date(),
): string {
  if (requested) {
    const monthMatch = MONTH_INPUT.exec(requested);
    if (monthMatch) {
      const month = Number(monthMatch[2]);
      if (month >= 1 && month <= 12) return `${requested}-01`;
    } else if (isTaxPeriodStart(requested)) {
      return requested;
    }
  }
  const previousMonth = new Date(
    Date.UTC(reference.getUTCFullYear(), reference.getUTCMonth() - 1, 1),
  );
  const year = previousMonth.getUTCFullYear();
  const month = String(previousMonth.getUTCMonth() + 1).padStart(2, "0");
  return `${year}-${month}-01`;
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

// ---- Filing & Evidence (P13 unbuilt-screens backlog, decision 238)
/** The types the Filing & Evidence screen offers for `tax_record_payment`/`tax_record_filing`/
 * `tax_reconcile_period` -- `wht_pph21` (the employee-withholding type) is settled through Payroll's own tax
 * ledger instead, never through this screen. PPh 4(2) and PPh 26 joined in decision 256. */
export type FilingTaxType = "vat" | "wht_pph23" | "wht_pph4_2" | "wht_pph26" | "final_umkm";
export const FILING_TAX_TYPES: readonly FilingTaxType[] = [
  "vat",
  "wht_pph23",
  "wht_pph4_2",
  "wht_pph26",
  "final_umkm",
];

/** The withholding taxes the Entity deducts from what it pays to vendors (Step 05 §10), in the order the
 * Withholding screen offers them. */
export type WithholdingTaxType = "wht_pph23" | "wht_pph4_2" | "wht_pph26";
export const WITHHOLDING_TAX_TYPES: readonly WithholdingTaxType[] = [
  "wht_pph23",
  "wht_pph4_2",
  "wht_pph26",
];

/** Falls back to PPh 23 for anything absent or not a vendor withholding. */
export function resolveWithholdingTaxType(requested: string | undefined): WithholdingTaxType {
  return requested && (WITHHOLDING_TAX_TYPES as readonly string[]).includes(requested)
    ? (requested as WithholdingTaxType)
    : "wht_pph23";
}

function isFilingTaxType(value: string): value is FilingTaxType {
  return (FILING_TAX_TYPES as readonly string[]).includes(value);
}

/** Falls back to `vat` for anything absent or outside the types this screen offers. */
export function resolveFilingTaxType(requested: string | undefined): FilingTaxType {
  return requested && isFilingTaxType(requested) ? requested : "vat";
}

/** A payment's paying account must hold the Entity's own base currency (`tax_record_payment`'s own check). */
export function eligibleTaxPaymentAccounts<T extends { currency: string }>(
  accounts: readonly T[],
  baseCurrency: string,
): T[] {
  return accounts.filter((a) => a.currency === baseCurrency);
}

// ---- Tax Rules / Configuration (P13 unbuilt-screens backlog, decision 239): vocabulary for the global rule
// master's own `family`/`status`/`verification_status` columns (`public.tax_rule_versions`,
// `20260925100000_p7_tax_facts_rules.sql`, later widened by the P8 fiscal-depreciation and P9 payroll-rules
// migrations) -- not a tax rate or threshold itself, only labels for what the row already says.
export type RuleFamily =
  | "ppn"
  | "pph23"
  | "pph_final_umkm"
  | "pph4_2"
  | "pph26"
  | "pph21"
  | "corporate_income"
  | "personal_income"
  | "deadline"
  | "fiscal_depreciation"
  | "bpjs"
  | "other";

export const RULE_FAMILY_LABELS: Readonly<Record<RuleFamily, string>> = {
  ppn: "PPN",
  pph23: "PPh 23",
  pph_final_umkm: "PPh Final UMKM",
  pph4_2: "PPh Pasal 4(2)",
  pph26: "PPh 26",
  pph21: "PPh 21",
  corporate_income: "PPh Badan",
  personal_income: "PPh Orang Pribadi",
  deadline: "Tenggat",
  fiscal_depreciation: "Penyusutan Fiskal",
  bpjs: "BPJS",
  other: "Lainnya",
};

export type RuleStatus = "draft" | "published" | "discarded";

export const RULE_STATUS_LABELS: Readonly<Record<RuleStatus, string>> = {
  draft: "Draf",
  published: "Diterbitkan",
  discarded: "Dibatalkan",
};

export const RULE_STATUS_TONE: Readonly<Record<RuleStatus, DeterminationTone>> = {
  draft: "neutral",
  published: "success",
  discarded: "attention",
};

export type RuleVerificationStatus = "verified" | "needs_review";

export const RULE_VERIFICATION_LABELS: Readonly<Record<RuleVerificationStatus, string>> = {
  verified: "Terverifikasi",
  needs_review: "Perlu Ditinjau",
};
