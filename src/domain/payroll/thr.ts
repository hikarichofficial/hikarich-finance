import { Decimal } from "@/domain/money/decimal";
import { currencyScale } from "@/domain/money/currency";

/**
 * THR Keagamaan: the religious-holiday allowance (OWNER, 10 October 2026; decision 400).
 *
 * Permenaker 6/2016 (Tunjangan Hari Raya Keagamaan bagi Pekerja/Buruh di Perusahaan):
 *   * article 2: owed to anyone with at least one continuous month of service;
 *   * article 3(1)(a): twelve months or more of service -> one month's wage;
 *   * article 3(1)(b): one to eleven months -> (months of service / 12) x one month's wage;
 *   * article 3(2): for a monthly-paid worker the wage is upah tanpa tunjangan, i.e. gaji pokok plus
 *     tunjangan tetap -- the same base BPJS contributions use, which is why `bpjs_wage_base` is read here
 *     and not `gross_pay` (overtime, bonuses and tunjangan tidak tetap are not part of it);
 *   * article 5(4): paid at the latest seven days before the holiday.
 *
 * Like the pro-rata helper (decision 388) this only works the figure out and offers it; it writes nothing.
 * The adjustment it fills in goes through `payroll_adjustment_add` exactly as a hand-typed one would, so a
 * company paying more than the regulation requires -- a collective agreement, a full month for everyone --
 * just edits the amount before saving. THR is taxable income for PPh 21, so the adjustment is taxable; from
 * PMK 168/2023 it is taxed through the month's TER like the rest of the month's gross, which the engine
 * already does once the adjustment is on the line.
 *
 * Months of service are whole completed months between the join date and the payment date: someone who
 * joined on 10 March has completed five months on 10 August and still five on 9 August. The regulation
 * counts masa kerja in months, so the remaining days do not add a fraction of a month here; a company that
 * counts them differently edits the figure.
 */

export interface ThrBasis {
  joinDate: string;
  /** When the THR is paid -- the run's pay date. Service is counted up to this day. */
  payDate: string;
  /** Gaji pokok plus tunjangan tetap, as the engine computed it for the line (`bpjs_wage_base`). */
  wageBase: string;
}

export interface Thr {
  monthsOfService: number;
  /** One month's wage: the full entitlement at twelve months or more. */
  fullAmount: string;
  /** What is owed: the full amount, or the proportional part below twelve months. */
  amount: string;
  proportional: boolean;
  /** The adjustment's name, which says on the payslip how the figure was arrived at. */
  label: string;
}

/** Whole completed months from `from` up to and including `to`; negative when they are the wrong way round. */
export function completedMonths(from: string, to: string): number {
  const a = {
    y: Number(from.slice(0, 4)),
    m: Number(from.slice(5, 7)),
    d: Number(from.slice(8, 10)),
  };
  const b = { y: Number(to.slice(0, 4)), m: Number(to.slice(5, 7)), d: Number(to.slice(8, 10)) };
  if (!Number.isInteger(a.y) || !Number.isInteger(b.y)) return 0;
  let months = (b.y - a.y) * 12 + (b.m - a.m);
  if (b.d < a.d) months -= 1;
  return months;
}

/**
 * The THR figures for one payroll line, or null when there is nothing to offer: less than one month of
 * service (nothing is owed yet) or no wage to divide.
 */
export function thrFor(basis: ThrBasis, currency: string): Thr | null {
  const months = completedMonths(basis.joinDate, basis.payDate);
  if (months < 1) return null;

  const scale = currencyScale(currency);
  const full = Decimal.parse(basis.wageBase).round(scale, "half_up");
  if (!full.isPositive()) return null;

  if (months >= 12) {
    return {
      monthsOfService: months,
      fullAmount: full.toString(),
      amount: full.toString(),
      proportional: false,
      label: "THR Keagamaan (1 bulan upah)",
    };
  }

  // Exact integer arithmetic on the minor units: multiply before dividing, so months/12 never rounds first.
  const part = Decimal.fromUnits((full.units * BigInt(months)) / 12n, full.scale);
  return {
    monthsOfService: months,
    fullAmount: full.toString(),
    amount: part.toString(),
    proportional: true,
    label: `THR Keagamaan proporsional (${months} dari 12 bulan)`,
  };
}
