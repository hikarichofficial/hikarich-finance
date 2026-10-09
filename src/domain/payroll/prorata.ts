import { Decimal } from "@/domain/money/decimal";
import { currencyScale } from "@/domain/money/currency";

/**
 * Pro-rating a month's pay for someone who did not work all of it (OWNER, 9 October 2026).
 *
 * The engine deliberately pays a mid-month joiner or leaver a full month and flags the line
 * (`joined_during_month` / `left_during_month`, `payroll_compute_line`): what a part month is worth is an
 * employment question, not an arithmetic one, so the payroll rules do not decide it. This works out the
 * figure and hands it to the Tambah Penyesuaian form; nothing here writes, and the adjustment it fills in
 * goes through `payroll_adjustment_add` exactly as a hand-typed one does.
 *
 * The split is by calendar days of the payroll period, counting the first and last day worked -- the measure
 * an Indonesian monthly-paid contract normally uses, and the only one this app can compute, since it holds no
 * working calendar and so cannot count hari kerja. A run that needs working days instead is still typed by
 * hand.
 *
 * The result is a deduction, not a smaller gross: the engine's figure stays as it is and the part that was
 * not worked comes off it. That deduction IS less income, so it lowers the PPh 21 base (decision 381) --
 * unlike a loan instalment, this is pay that was never earned.
 */

export interface ProrataBasis {
  /** First day of the payroll period, ISO. */
  periodStart: string;
  /** Last day of the payroll period, ISO. */
  periodEnd: string;
  joinDate: string;
  exitDate: string | null;
  /** The month's gross pay as the engine computed it, before this deduction. */
  grossPay: string;
}

export interface Prorata {
  daysWorked: number;
  daysInPeriod: number;
  /** What the month is worth for the days actually worked. */
  proratedGross: string;
  /** Gross minus the prorated gross: the adjustment to record. */
  deduction: string;
  /** The adjustment's name, which says on the payslip how the figure was arrived at. */
  label: string;
}

const DAY = 86_400_000;

/** Whole days between two ISO dates, counting both ends; negative when they are the wrong way round. */
function inclusiveDays(from: string, to: string): number {
  const a = Date.parse(`${from}T00:00:00Z`);
  const b = Date.parse(`${to}T00:00:00Z`);
  if (Number.isNaN(a) || Number.isNaN(b)) return 0;
  return Math.round((b - a) / DAY) + 1;
}

function later(a: string, b: string): string {
  return a > b ? a : b;
}

function earlier(a: string, b: string): string {
  return a < b ? a : b;
}

/**
 * The pro-rata figures for one payroll line, or null when there is nothing to pro-rate: a full month worked,
 * no pay to divide, or dates that do not overlap the period at all.
 */
export function prorataFor(basis: ProrataBasis, currency: string): Prorata | null {
  const { periodStart, periodEnd, joinDate, exitDate, grossPay } = basis;
  const daysInPeriod = inclusiveDays(periodStart, periodEnd);
  if (daysInPeriod <= 0) return null;

  const from = later(joinDate, periodStart);
  const to = earlier(exitDate ?? periodEnd, periodEnd);
  const daysWorked = inclusiveDays(from, to);
  if (daysWorked <= 0 || daysWorked >= daysInPeriod) return null;

  const scale = currencyScale(currency);
  const gross = Decimal.parse(grossPay).round(scale, "half_up");
  if (!gross.isPositive()) return null;

  // Exact integer arithmetic on the minor units, so the two parts always add back up to the gross.
  const proratedUnits = (gross.units * BigInt(daysWorked)) / BigInt(daysInPeriod);
  const prorated = Decimal.fromUnits(proratedUnits, gross.scale);

  return {
    daysWorked,
    daysInPeriod,
    proratedGross: prorated.toString(),
    deduction: gross.sub(prorated).toString(),
    label: `Prorata masa kerja (${daysWorked} dari ${daysInPeriod} hari)`,
  };
}
