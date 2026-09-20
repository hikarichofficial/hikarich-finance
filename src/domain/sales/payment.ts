import { Decimal, sumDecimals } from "@/domain/money/decimal";
import { convertAmount, currencyScale } from "@/domain/money/currency";

/**
 * Pure pre-check of a customer payment (P5, Step 07 §5-§7, Step 08 §9) with the arithmetic of
 * `app_private.confirm_payment_core`: every allocation books its accounts-receivable part at the value the
 * invoice carries (a partial payment takes a proportional share of the remaining base value, and the payment
 * that clears an invoice takes exactly what is left), the cash side is converted at the payment's own rate, and
 * the difference is the exchange gain or loss. The database recomputes and re-validates everything under the
 * invoice locks; this only gives the person an early answer.
 *
 * A payment never creates revenue: revenue was booked when the invoice was issued. Anything beyond the
 * allocated invoices is kept as a customer advance only when the person says so explicitly.
 */

export interface PaymentAllocationDraft {
  /** What this payment settles on the invoice, in the invoice (= receiving account) currency. */
  amount: string;
  /** Still outstanding on the invoice before this payment, in the invoice currency. */
  outstanding: string;
  /** The same outstanding in the Entity base currency. */
  outstandingBase: string;
}

export interface PaymentDraft {
  baseCurrency: string;
  /** Currency of the receiving account (and of every allocated invoice). */
  accountCurrency: string;
  amount: string;
  /** Required exactly when the account is not in the base currency. */
  rate?: string;
  allocations: readonly PaymentAllocationDraft[];
  /** The person's explicit choice to keep any excess as a customer advance. */
  allowAdvance?: boolean;
}

export interface PaymentFigures {
  allocated: Decimal;
  advance: Decimal;
  /** The whole payment in base currency, as the cash movement will book it. */
  cashBase: Decimal;
  /** The part of the cash that settles invoices, in base currency. */
  allocatedCashBase: Decimal;
  advanceBase: Decimal;
  /** Accounts-receivable credit per allocation, in the same order as the drafts. */
  receivableBase: Decimal[];
  /** allocatedCashBase - sum(receivableBase): positive = gain, negative = loss. */
  fxDifference: Decimal;
}

export type PaymentProblem =
  | "amount_invalid"
  | "too_many_decimals"
  | "rate_required"
  | "rate_not_allowed"
  | "rate_invalid"
  | "allocation_invalid"
  | "allocation_exceeds_outstanding"
  | "allocations_exceed_payment"
  | "advance_not_confirmed"
  | "too_small"
  | "advance_too_small"
  | "fx_difference_too_large";

export type PaymentCheck =
  | { ok: true; figures: PaymentFigures }
  | { ok: false; problem: PaymentProblem; allocation?: number };

const AMOUNT_LIMIT = Decimal.parse("10000000000000"); // 10^13
const RATE_LIMIT = Decimal.parse("10000000000"); // 10^10
const RATE_SCALE = 10;

const ZERO = BigInt(0);
const ONE = BigInt(1);
const TWO = BigInt(2);
const TEN = BigInt(10);

/** numerator / denominator, rounded half-up (ties away from zero) to `scale` digits, in integers only. */
function divideRounded(numerator: Decimal, denominator: Decimal, scale: number): Decimal {
  if (denominator.units === ZERO) throw new RangeError("Division by zero");
  // (n.units / 10^n.scale) / (d.units / 10^d.scale) = n.units * 10^d.scale / (d.units * 10^n.scale)
  let top = numerator.units * TEN ** BigInt(denominator.scale + scale);
  let bottom = denominator.units * TEN ** BigInt(numerator.scale);
  const topNegative = top < ZERO;
  const bottomNegative = bottom < ZERO;
  const negative = topNegative !== bottomNegative;
  if (topNegative) top = -top;
  if (bottomNegative) bottom = -bottom;
  let quotient = top / bottom;
  if ((top % bottom) * TWO >= bottom) quotient += ONE;
  return Decimal.fromUnits(negative ? -quotient : quotient, scale);
}

/**
 * Base value of a settlement. Mirrors `app_private.prorate_remaining`: the payment that clears the invoice
 * takes exactly the remaining base value; anything less takes a proportional share, rounded half-up once.
 */
export function prorateRemaining(
  remainingAmount: Decimal,
  remainingBase: Decimal,
  amount: Decimal,
  baseScale: number,
): Decimal {
  if (!amount.isPositive() || amount.cmp(remainingAmount) > 0) {
    throw new RangeError("The amount exceeds what remains");
  }
  if (amount.eq(remainingAmount)) return remainingBase;
  return divideRounded(amount.mul(remainingBase), remainingAmount, baseScale);
}

export function checkPayment(draft: PaymentDraft): PaymentCheck {
  const fail = (problem: PaymentProblem, allocation?: number): PaymentCheck => ({
    ok: false,
    problem,
    allocation,
  });
  const baseScale = currencyScale(draft.baseCurrency);
  const accountScale = currencyScale(draft.accountCurrency);
  const foreign = draft.accountCurrency !== draft.baseCurrency;

  const amount = Decimal.tryParse(draft.amount);
  if (!amount || !amount.isPositive() || amount.cmp(AMOUNT_LIMIT) >= 0) {
    return fail("amount_invalid");
  }
  if (!amount.fitsScale(accountScale)) return fail("too_many_decimals");

  const rateText = draft.rate === undefined || draft.rate === "" ? undefined : draft.rate;
  if (foreign && rateText === undefined) return fail("rate_required");
  if (!foreign && rateText !== undefined) return fail("rate_not_allowed");
  let rate: Decimal | null = null;
  if (rateText !== undefined) {
    rate = Decimal.tryParse(rateText);
    if (!rate || !rate.isPositive() || rate.cmp(RATE_LIMIT) >= 0 || !rate.fitsScale(RATE_SCALE)) {
      return fail("rate_invalid");
    }
  }

  const allocated: Decimal[] = [];
  const receivable: Decimal[] = [];
  for (const [index, item] of draft.allocations.entries()) {
    const part = Decimal.tryParse(item.amount);
    const outstanding = Decimal.tryParse(item.outstanding);
    const outstandingBase = Decimal.tryParse(item.outstandingBase);
    if (
      !part ||
      !part.isPositive() ||
      !part.fitsScale(accountScale) ||
      !outstanding ||
      !outstandingBase
    ) {
      return fail("allocation_invalid", index);
    }
    if (part.cmp(outstanding) > 0) return fail("allocation_exceeds_outstanding", index);
    allocated.push(part);
    receivable.push(prorateRemaining(outstanding, outstandingBase, part, baseScale));
  }

  const allocatedTotal = sumDecimals(allocated);
  if (allocatedTotal.cmp(amount) > 0) return fail("allocations_exceed_payment");
  const advance = amount.sub(allocatedTotal);
  if (advance.isPositive() && !draft.allowAdvance) return fail("advance_not_confirmed");

  const toBase = (value: Decimal): Decimal =>
    rate === null ? value : convertAmount(value, rate, draft.baseCurrency);
  const cashBase = toBase(amount);
  const allocatedCashBase = toBase(allocatedTotal);
  if (!cashBase.isPositive()) return fail("too_small");
  const advanceBase = cashBase.sub(allocatedCashBase);
  if (advance.isPositive() && !advanceBase.isPositive()) return fail("advance_too_small");
  const receivableTotal = sumDecimals(receivable);
  const fxDifference = allocatedCashBase.sub(receivableTotal);
  // The database refuses an exchange difference above 20% of the settled cash (a mistyped rate, not FX).
  if (
    allocatedTotal.isPositive() &&
    fxDifference.abs().mul(Decimal.fromInteger(5)).cmp(allocatedCashBase) > 0
  ) {
    return fail("fx_difference_too_large");
  }

  return {
    ok: true,
    figures: {
      allocated: allocatedTotal,
      advance,
      cashBase,
      allocatedCashBase,
      advanceBase,
      receivableBase: receivable,
      fxDifference,
    },
  };
}

const MESSAGES: Readonly<Record<PaymentProblem, string>> = {
  amount_invalid: "Jumlah pembayaran harus angka lebih dari nol.",
  too_many_decimals: "Jumlah melebihi desimal yang diizinkan mata uang akun penerima.",
  rate_required: "Kurs wajib diisi untuk akun bermata uang asing.",
  rate_not_allowed: "Kurs tidak diisi untuk akun bermata uang dasar.",
  rate_invalid: "Kurs tidak valid (angka positif, maks. 10 desimal).",
  allocation_invalid: "Alokasi ke faktur tidak valid.",
  allocation_exceeds_outstanding: "Alokasi melebihi sisa tagihan faktur tersebut.",
  allocations_exceed_payment: "Total alokasi melebihi jumlah pembayaran.",
  advance_not_confirmed:
    "Pembayaran melebihi faktur yang dipilih. Alokasikan sisanya atau pilih secara eksplisit untuk menyimpannya sebagai uang muka pelanggan.",
  too_small: "Jumlah terlalu kecil untuk dibukukan dalam mata uang dasar.",
  advance_too_small: "Uang muka terlalu kecil untuk dibukukan dalam mata uang dasar.",
  fx_difference_too_large: "Selisih kurs melebihi 20% dari jumlah; periksa kembali kurs.",
};

export function paymentProblemMessage(problem: PaymentProblem, allocation?: number): string {
  return allocation === undefined
    ? MESSAGES[problem]
    : `Alokasi ${allocation + 1}: ${MESSAGES[problem]}`;
}
