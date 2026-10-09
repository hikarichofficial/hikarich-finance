import { Decimal, type RoundingMode } from "@/domain/money/decimal";

/**
 * Loans, other receivables/payables and equity (P8, Step 15 §12, Step 16 §16-17). The database is the only
 * authority for what is posted and owed; this module holds the labels and the schedule arithmetic that a screen
 * needs for early feedback ("what would this loan look like") with the same rounding as `app_private.loan_plan`.
 * Nothing here is stored: an installment schedule shown on a form is a preview, and the schedule that binds is the
 * one the database writes when the loan is created.
 */

export type LoanDirection = "borrowed" | "lent";
export type LoanStatus = "draft" | "active" | "closed" | "cancelled";
export type LoanMethod = "annuity" | "flat" | "interest_only" | "manual";
export type ObligationKind = "receivable" | "payable";
export type ObligationStatus = "open" | "settled" | "void";
export type EquityKind =
  | "contribution"
  | "capital_return"
  | "dividend"
  | "investment_contribution"
  | "investment_return"
  | "distribution_received";
export type EquityStatus = "draft" | "confirmed" | "reversed" | "cancelled";
export type EquityClass = "capital" | "additional";
export type TaxReviewStatus = "not_applicable" | "needs_review" | "reviewed";

export const LOAN_DIRECTION_LABELS: Readonly<Record<LoanDirection, string>> = {
  borrowed: "Pinjaman diterima",
  lent: "Pinjaman diberikan",
};

export const LOAN_STATUS_LABELS: Readonly<Record<LoanStatus, string>> = {
  draft: "Draf",
  active: "Berjalan",
  closed: "Lunas",
  cancelled: "Dibatalkan",
};

export const LOAN_METHOD_LABELS: Readonly<Record<LoanMethod, string>> = {
  annuity: "Anuitas",
  flat: "Bunga flat",
  interest_only: "Hanya bunga (pokok di akhir)",
  manual: "Jadwal manual",
};

export const OBLIGATION_KIND_LABELS: Readonly<Record<ObligationKind, string>> = {
  receivable: "Piutang lain-lain",
  payable: "Utang lain-lain",
};

export const OBLIGATION_STATUS_LABELS: Readonly<Record<ObligationStatus, string>> = {
  open: "Berjalan",
  settled: "Lunas",
  void: "Dibatalkan",
};

export const EQUITY_KIND_LABELS: Readonly<Record<EquityKind, string>> = {
  contribution: "Setoran modal",
  capital_return: "Pengembalian modal",
  dividend: "Dividen",
  investment_contribution: "Penyertaan modal",
  investment_return: "Pengembalian penyertaan",
  distribution_received: "Distribusi diterima",
};

export const EQUITY_STATUS_LABELS: Readonly<Record<EquityStatus, string>> = {
  draft: "Draf",
  confirmed: "Terkonfirmasi",
  reversed: "Dibalik",
  cancelled: "Dibatalkan",
};

export const EQUITY_CLASS_LABELS: Readonly<Record<EquityClass, string>> = {
  capital: "Modal Disetor",
  additional: "Tambahan (Agio dan sejenisnya)",
};

export const TAX_REVIEW_LABELS: Readonly<Record<TaxReviewStatus, string>> = {
  not_applicable: "Tidak ada tinjauan pajak",
  needs_review: "Perlu tinjauan pajak",
  reviewed: "Sudah ditinjau",
};

/** Kinds that need the owner's approval (`equity.approve`) and a fresh step-up: they take value out of the company. */
export function equityNeedsApproval(kind: EquityKind): boolean {
  return kind === "capital_return" || kind === "dividend";
}

// ---- exact division (the Decimal class has none)
const ZERO = BigInt(0);
const ONE = BigInt(1);
const TWO = BigInt(2);
const TEN = BigInt(10);

function pow10(exponent: number): bigint {
  return TEN ** BigInt(exponent);
}

/** numerator / denominator rounded half-up (away from zero on ties), on integers. */
function divideHalfUp(numerator: bigint, denominator: bigint): bigint {
  const negative = numerator < ZERO !== denominator < ZERO;
  const n = numerator < ZERO ? -numerator : numerator;
  const d = denominator < ZERO ? -denominator : denominator;
  let quotient = n / d;
  if ((n % d) * TWO >= d) quotient += ONE;
  return negative ? -quotient : quotient;
}

/**
 * `numerator / denominator` rounded half-up to `scale` fraction digits, exactly: the same result as PostgreSQL's
 * `round(a / b, scale)` whenever the quotient does not fall within the last digits of its own working precision.
 */
export function divideRounded(numerator: Decimal, denominator: Decimal, scale: number): Decimal {
  if (denominator.isZero()) throw new RangeError("Division by zero");
  const units = divideHalfUp(
    numerator.units * pow10(denominator.scale + scale),
    denominator.units * pow10(numerator.scale),
  );
  return Decimal.fromUnits(units, scale);
}

// ---- dates
function parseIsoDate(value: string): { year: number; month: number; day: number } {
  const [year, month, day] = value.split("-").map(Number);
  return { year, month, day };
}

function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

/** PostgreSQL's `date + interval 'N months'`: the day is kept, or clamped to the end of a shorter month. */
export function addMonthsClamped(isoDate: string, months: number): string {
  const { year, month, day } = parseIsoDate(isoDate);
  const index = year * 12 + (month - 1) + months;
  const y = Math.floor(index / 12);
  const m = (index % 12) + 1;
  const d = Math.min(day, daysInMonth(y, m));
  return `${String(y).padStart(4, "0")}-${String(m).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
}

// ---- the installment schedule
export type GeneratedLoanMethod = Exclude<LoanMethod, "manual">;

export interface LoanPlanInput {
  method: GeneratedLoanMethod;
  principal: string;
  /** Annual interest rate in percent, e.g. "12" or "9.75". */
  ratePercent: string;
  installments: number;
  stepMonths: 1 | 3 | 6 | 12;
  firstDue: string;
  /** Fraction digits of the currency (2 for IDR); defaults to 2. */
  scale?: number;
}

export interface LoanPlanRow {
  seq: number;
  dueDate: string;
  principal: Decimal;
  interest: Decimal;
  total: Decimal;
}

export type LoanPlanProblem =
  "principal" | "rate" | "installments" | "step" | "method" | "first_due";

export type LoanPlanResult =
  | { ok: true; rows: LoanPlanRow[]; totalInterest: Decimal }
  | { ok: false; problem: LoanPlanProblem };

const HALF_UP: RoundingMode = "half_up";

/**
 * The schedule of a loan (mirrors `app_private.loan_plan`): annuity (equal payments), flat (interest on the original
 * principal, equal principal parts) and interest-only (principal at the end). The last installment absorbs the
 * rounding, so the principal always adds up exactly. Interest is a schedule figure only: the ledger books interest
 * when it is paid (DECISIONS 108).
 */
export function loanPlan(input: LoanPlanInput): LoanPlanResult {
  const scale = input.scale ?? 2;
  const principal = Decimal.tryParse(input.principal);
  const rate = Decimal.tryParse(input.ratePercent);
  if (!["annuity", "flat", "interest_only"].includes(input.method))
    return { ok: false, problem: "method" };
  if (!principal || !principal.isPositive() || !principal.fitsScale(scale))
    return { ok: false, problem: "principal" };
  if (!rate || rate.isNegative() || rate.cmp(Decimal.fromInteger(100)) > 0)
    return { ok: false, problem: "rate" };
  if (!Number.isInteger(input.installments) || input.installments < 1 || input.installments > 600) {
    return { ok: false, problem: "installments" };
  }
  if (![1, 3, 6, 12].includes(input.stepMonths)) return { ok: false, problem: "step" };
  if (!/^\d{4}-\d{2}-\d{2}$/.test(input.firstDue)) return { ok: false, problem: "first_due" };

  const n = input.installments;
  // The rate of one step: rate% x step / 12 months = rate x step / 1200, kept as a fraction.
  const ratePerStep = rate.mul(Decimal.fromInteger(input.stepMonths));
  const interestOn = (base: Decimal): Decimal =>
    divideRounded(base.mul(ratePerStep), Decimal.fromInteger(1200), scale);

  let payment = Decimal.zero(scale);
  if (input.method === "annuity") {
    if (ratePerStep.isZero()) {
      payment = divideRounded(principal, Decimal.fromInteger(n), scale);
    } else {
      // pmt = P x r x (1+r)^n / ((1+r)^n - 1) with r = rn / rd, evaluated as one exact fraction.
      const rn = ratePerStep.units;
      const rd = pow10(ratePerStep.scale) * BigInt(1200);
      const grown = (rd + rn) ** BigInt(n);
      const base = rd ** BigInt(n);
      const units = divideHalfUp(
        principal.units * rn * grown * pow10(scale),
        pow10(principal.scale) * rd * (grown - base),
      );
      payment = Decimal.fromUnits(units, scale);
    }
  }

  const rows: LoanPlanRow[] = [];
  let balance = principal.round(scale);
  let totalInterest = Decimal.zero(scale);
  for (let k = 1; k <= n; k += 1) {
    const last = k === n;
    let interest: Decimal;
    let part: Decimal;
    if (input.method === "flat") {
      interest = interestOn(principal);
      const equal = divideRounded(principal, Decimal.fromInteger(n), scale);
      part = last ? balance : equal.cmp(balance) < 0 ? equal : balance;
    } else if (input.method === "interest_only") {
      interest = interestOn(balance);
      part = last ? balance : Decimal.zero(scale);
    } else {
      interest = interestOn(balance);
      const wanted = payment.sub(interest);
      const bounded = wanted.isNegative() ? Decimal.zero(scale) : wanted;
      part = last ? balance : bounded.cmp(balance) < 0 ? bounded : balance;
    }
    rows.push({
      seq: k,
      dueDate: addMonthsClamped(input.firstDue, (k - 1) * input.stepMonths),
      principal: part.round(scale, HALF_UP),
      interest,
      total: part.add(interest).round(scale, HALF_UP),
    });
    balance = balance.sub(part);
    totalInterest = totalInterest.add(interest);
  }
  return { ok: true, rows, totalInterest };
}

export function loanPlanProblemMessage(problem: LoanPlanProblem): string {
  switch (problem) {
    case "principal":
      return "Pokok pinjaman harus lebih dari nol dan sesuai desimal mata uang.";
    case "rate":
      return "Bunga per tahun harus antara 0 dan 100 persen.";
    case "installments":
      return "Jumlah cicilan antara 1 dan 600.";
    case "step":
      return "Jarak cicilan 1, 3, 6 atau 12 bulan.";
    case "method":
      return "Metode jadwal tidak dikenal.";
    case "first_due":
      return "Tanggal cicilan pertama tidak valid.";
  }
}

/** The principal still owed from what was funded and what active payments repaid or wrote off. */
export function loanOutstanding(funded: string, repaid: string, writtenOff = "0"): Decimal {
  const result = Decimal.parse(funded).sub(Decimal.parse(repaid)).sub(Decimal.parse(writtenOff));
  return result.isNegative() ? Decimal.zero(result.scale) : result;
}

// ---- Bunga Berjenjang entered by year (decision 375)
export interface RateStepYearRow {
  year: number;
  rate: string;
}

export type RateStepYearsResult =
  | { ok: true; steps: { from: string; rate: string }[] }
  | { ok: false; message: string };

/**
 * Turns "from year N of the schedule, rate R" rows into the dated steps the database stores. Year 1 starts at the
 * first installment, so year N starts at the installment due (N - 1) years after it -- the same date
 * `app_private.loan_plan` gives that installment (first due plus whole months, clamped to the month end). Years
 * must be whole, start at 2 (year 1 is the opening rate), rise strictly and stay within the schedule.
 */
export function rateStepsFromYears(
  firstDue: string,
  installments: number,
  stepMonths: number,
  rows: readonly RateStepYearRow[],
): RateStepYearsResult {
  if (rows.length === 0) return { ok: true, steps: [] };
  if (!firstDue) {
    return { ok: false, message: "Isi Tanggal Cicilan Pertama sebelum mengisi tahap bunga." };
  }
  const totalYears = Math.ceil((installments * stepMonths) / 12);
  const steps: { from: string; rate: string }[] = [];
  let previous = 1;
  for (const row of rows) {
    if (!Number.isInteger(row.year) || row.year < 2) {
      return {
        ok: false,
        message: "Tahap bunga dimulai paling cepat tahun ke-2 (tahun ke-1 memakai bunga awal).",
      };
    }
    if (row.year <= previous) {
      return { ok: false, message: "Tahun pada tahap bunga harus urut naik dan tidak boleh sama." };
    }
    if (row.year > totalYears) {
      return {
        ok: false,
        message: `Tahun ke-${row.year} melewati jangka pinjaman (${totalYears} tahun).`,
      };
    }
    steps.push({ from: addMonthsClamped(firstDue, (row.year - 1) * 12), rate: row.rate });
    previous = row.year;
  }
  return { ok: true, steps };
}

// ---- paying the next N instalments (decision 376)
/** What is still owed on one instalment that is not fully paid (due less what was paid). */
export interface UnpaidInstallment {
  seq: number;
  due_date: string;
  principal: string;
  interest: string;
  fee: string;
}

export interface InstallmentTotals {
  count: number;
  principal: string;
  interest: string;
  fee: string;
  total: string;
}

/**
 * The amounts of the next `count` unpaid instalments, as the form previews them. The database computes the same
 * sum itself (`loan_pay_installments`); this is only what the person sees before saving.
 */
export function sumNextInstallments(
  rows: readonly UnpaidInstallment[],
  count: number,
): InstallmentTotals {
  const take = [...rows].sort((a, b) => a.seq - b.seq).slice(0, Math.max(0, Math.floor(count)));
  const scale = take.length > 0 ? Decimal.parse(take[0].principal).scale : 0;
  let principal = Decimal.zero(scale);
  let interest = Decimal.zero(scale);
  let fee = Decimal.zero(scale);
  for (const row of take) {
    principal = principal.add(Decimal.parse(row.principal));
    interest = interest.add(Decimal.parse(row.interest));
    fee = fee.add(Decimal.parse(row.fee));
  }
  return {
    count: take.length,
    principal: principal.toString(),
    interest: interest.toString(),
    fee: fee.toString(),
    total: principal.add(interest).add(fee).toString(),
  };
}

/** One row of `loan_schedule`, as far as the unpaid view needs it. */
export interface ScheduleRowForPayment {
  version_no: number;
  seq: number;
  due_date: string;
  principal_due: string;
  interest_due: string;
  fee_due: string;
  paid_principal: string;
  paid_interest: string;
  paid_fee: string;
  state: string;
}

function remaining(due: string, paid: string): string {
  const left = Decimal.parse(due).sub(Decimal.parse(paid));
  return (left.isNegative() ? Decimal.zero(left.scale) : left).toString();
}

/** The instalments of one schedule version that are not fully paid, with what is still owed on each. */
export function unpaidInstallments(
  rows: readonly ScheduleRowForPayment[],
  versionNo: number | undefined,
): UnpaidInstallment[] {
  return rows
    .filter((row) => row.version_no === versionNo && row.state !== "paid")
    .map((row) => ({
      seq: row.seq,
      due_date: row.due_date,
      principal: remaining(row.principal_due, row.paid_principal),
      interest: remaining(row.interest_due, row.paid_interest),
      fee: remaining(row.fee_due, row.paid_fee),
    }))
    .sort((a, b) => a.seq - b.seq);
}
