import { Decimal } from "@/domain/money/decimal";

/**
 * Payroll (P9, Step 05 §15, Step 12): employees, the monthly run, PPh 21 and BPJS. The database is the only
 * authority for what is calculated, posted and owed; this module holds the vocabulary a screen needs (labels, flag
 * descriptions, the state machine as the screen sees it) and two pure checks that let a payslip or a run summary be
 * shown consistently. No tax or BPJS rule lives here: rates, caps and brackets are effective-dated rule data in the
 * database, and a screen shows the numbers the run stored.
 */

export type EmploymentType = "permanent" | "contract" | "probation" | "part_time";
export type EmployeeStatus = "active" | "ended";
export type CompensationKind = "earning" | "deduction";
export type TaxIdStatus = "has_tax_id" | "no_tax_id" | "unknown";
export type PtkpStatus =
  "TK/0" | "TK/1" | "TK/2" | "TK/3" | "K/0" | "K/1" | "K/2" | "K/3" | "unknown";
export type TaxMethod = "employee_borne" | "gross_up";
export type BpjsComponent = "bpjs_kes" | "bpjs_jht" | "bpjs_jp" | "bpjs_jkk" | "bpjs_jkm";
export type PayrollStatus =
  | "draft"
  | "calculated"
  | "submitted"
  | "approved"
  | "posted"
  | "partially_paid"
  | "paid"
  | "closed"
  | "corrected"
  | "discarded";
export type PayrollPaymentKind = "net_pay" | "bpjs";
export type PayrollPaymentStatus = "confirmed" | "reversed";
export type PayslipStatus = "issued" | "voided";
export type PayrollTaxMode = "ter" | "annual";
export type PayrollLiability = "net_pay" | "bpjs" | "pph21";

export const EMPLOYMENT_TYPE_LABELS: Readonly<Record<EmploymentType, string>> = {
  permanent: "Karyawan tetap",
  contract: "Kontrak",
  probation: "Percobaan",
  part_time: "Paruh waktu",
};

export const EMPLOYEE_STATUS_LABELS: Readonly<Record<EmployeeStatus, string>> = {
  active: "Aktif",
  ended: "Berhenti",
};

export const COMPENSATION_KIND_LABELS: Readonly<Record<CompensationKind, string>> = {
  earning: "Penghasilan",
  deduction: "Potongan",
};

export const TAX_ID_STATUS_LABELS: Readonly<Record<TaxIdStatus, string>> = {
  has_tax_id: "Punya NPWP/NIK",
  no_tax_id: "Tidak punya NPWP/NIK",
  unknown: "Belum diketahui",
};

export const PTKP_STATUSES: readonly PtkpStatus[] = [
  "TK/0",
  "TK/1",
  "TK/2",
  "TK/3",
  "K/0",
  "K/1",
  "K/2",
  "K/3",
  "unknown",
];

export const TAX_METHOD_LABELS: Readonly<Record<TaxMethod, string>> = {
  employee_borne: "Ditanggung karyawan",
  gross_up: "Ditanggung perusahaan (gross-up)",
};

export const BPJS_COMPONENT_LABELS: Readonly<Record<BpjsComponent, string>> = {
  bpjs_kes: "BPJS Kesehatan",
  bpjs_jht: "BPJS JHT",
  bpjs_jp: "BPJS JP",
  bpjs_jkk: "BPJS JKK",
  bpjs_jkm: "BPJS JKM",
};

export const PAYROLL_STATUS_LABELS: Readonly<Record<PayrollStatus, string>> = {
  draft: "Draf",
  calculated: "Sudah dihitung",
  submitted: "Diajukan",
  approved: "Disetujui",
  posted: "Terposting",
  partially_paid: "Dibayar sebagian",
  paid: "Dibayar penuh",
  closed: "Ditutup",
  corrected: "Dikoreksi",
  discarded: "Dibuang",
};

export const PAYROLL_PAYMENT_KIND_LABELS: Readonly<Record<PayrollPaymentKind, string>> = {
  net_pay: "Gaji bersih",
  bpjs: "BPJS",
};

export const PAYROLL_PAYMENT_STATUS_LABELS: Readonly<Record<PayrollPaymentStatus, string>> = {
  confirmed: "Terkonfirmasi",
  reversed: "Dibalik",
};

export const PAYSLIP_STATUS_LABELS: Readonly<Record<PayslipStatus, string>> = {
  issued: "Diterbitkan",
  voided: "Dibatalkan",
};

export const PAYROLL_TAX_MODE_LABELS: Readonly<Record<PayrollTaxMode, string>> = {
  ter: "Tarif efektif bulanan (TER)",
  annual: "Perhitungan tahunan (Pasal 17)",
};

export const PAYROLL_LIABILITY_LABELS: Readonly<Record<PayrollLiability, string>> = {
  net_pay: "Gaji bersih",
  bpjs: "BPJS",
  pph21: "PPh 21",
};

/** The three PMK 168/2023 TER categories a PTKP status falls into (the rate tables are database rule data). */
export function terCategory(status: PtkpStatus): "A" | "B" | "C" | null {
  switch (status) {
    case "TK/0":
    case "TK/1":
    case "K/0":
      return "A";
    case "TK/2":
    case "TK/3":
    case "K/1":
    case "K/2":
      return "B";
    case "K/3":
      return "C";
    default:
      return null;
  }
}

/** Statuses from which a run can still be edited, submitted or discarded. */
export function payrollIsEditable(status: PayrollStatus): boolean {
  return status === "draft" || status === "calculated";
}

/** Statuses in which the run's journal exists and money can be paid against it. */
export function payrollIsPayable(status: PayrollStatus): boolean {
  return status === "posted" || status === "partially_paid" || status === "paid";
}

/** What the screen may offer next. The database still decides (permission, step-up, maker-checker, staleness). */
export function payrollNextActions(status: PayrollStatus): readonly string[] {
  switch (status) {
    case "draft":
      return ["calculate", "discard"];
    case "calculated":
      return ["calculate", "adjust", "submit", "discard"];
    case "submitted":
      return ["return", "approve"];
    case "approved":
      return ["return", "post"];
    case "posted":
    case "partially_paid":
    case "paid":
      return ["pay", "close", "correct"];
    case "closed":
      return ["reopen"];
    default:
      return [];
  }
}

const FLAG_TEXT: Readonly<Record<string, string>> = {
  no_compensation: "Karyawan belum punya komponen gaji pada bulan ini.",
  tax_facts_missing: "Data pajak karyawan (NPWP/NIK atau status PTKP) belum lengkap.",
  no_ter_rule: "Tidak ada aturan tarif efektif (TER) yang berlaku untuk bulan ini.",
  no_annual_rule: "Tidak ada aturan perhitungan tahunan yang berlaku untuk tahun ini.",
  ytd_incomplete:
    "Data penghasilan dan pajak bulan-bulan sebelumnya belum lengkap; isi saldo awal pajak atau selesaikan bulan sebelumnya.",
  earlier_run_not_posted: "Ada bulan sebelumnya pada tahun pajak yang sama yang belum diposting.",
  gross_up_not_converged: "Perhitungan gross-up tidak konvergen; periksa data karyawan.",
  negative_gross_pay: "Penghasilan bruto negatif; periksa potongan dan penyesuaian.",
  negative_net_pay: "Gaji bersih negatif; periksa potongan dan penyesuaian.",
};

/**
 * A human-readable explanation of a review or info flag on a payroll line. Flags with a value carry it after a
 * colon (`no_bpjs_rule:bpjs_jp`, `bpjs_rate_option_missing:bpjs_jkk`, `tax_overwithheld:29135`); an unknown flag is
 * shown as it came so nothing the database says is hidden.
 */
export function describePayrollFlag(flag: string): string {
  const known = FLAG_TEXT[flag];
  if (known) return known;
  const [code, value = ""] = flag.split(":", 2);
  if (code === "no_bpjs_rule") {
    const label = BPJS_COMPONENT_LABELS[value as BpjsComponent] ?? value;
    return `Belum ada aturan ${label} yang berlaku untuk bulan ini; iuran tidak dihitung.`;
  }
  if (code === "bpjs_rate_option_missing") {
    const label = BPJS_COMPONENT_LABELS[value as BpjsComponent] ?? value;
    return `Pilihan tarif ${label} belum diisi pada data BPJS karyawan.`;
  }
  if (code === "tax_overwithheld") {
    return `PPh 21 yang sudah dipotong lebih besar ${value} dari perhitungan; tidak dikembalikan melalui penggajian.`;
  }
  return flag;
}

/** True when the flag only informs (nothing blocks posting). */
export function isInfoFlag(flag: string): boolean {
  return flag.startsWith("tax_overwithheld:");
}

/**
 * Net pay as the payslip states it: gross pay, less the employee BPJS, less the PPh 21 the employee bears (the
 * withholding minus the allowance the company pays on top in a gross-up). A screen can show this check beside the
 * database's figure; a mismatch is reported by the database as `net_pay_formula`.
 */
export function expectedNetPay(input: {
  gross_pay: string;
  bpjs_employee: string;
  pph21: string;
  tax_allowance: string;
}): Decimal {
  return Decimal.parse(input.gross_pay)
    .sub(Decimal.parse(input.bpjs_employee))
    .sub(Decimal.parse(input.pph21).sub(Decimal.parse(input.tax_allowance)));
}

/** What is still owed to employees on one payroll line. */
export function netOutstanding(line: { net_pay: string; net_paid: string }): Decimal {
  return Decimal.parse(line.net_pay).sub(Decimal.parse(line.net_paid));
}

/** "2025-07" style label for a payroll month, from a first-of-month date. */
export function payrollPeriodLabel(periodStart: string): string {
  return periodStart.slice(0, 7);
}

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

/** "Juli 2025" for a `YYYY-MM-DD` or `YYYY-MM` period. */
export function payrollPeriodName(period: string): string {
  const year = period.slice(0, 4);
  const month = Number(period.slice(5, 7));
  const name = MONTHS_ID[month - 1];
  return name ? `${name} ${year}` : period;
}
