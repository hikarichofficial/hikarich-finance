import { Decimal, sumDecimals } from "@/domain/money/decimal";
import { convertAmount, currencyScale } from "@/domain/money/currency";
import { prorateRemaining } from "@/domain/sales/payment";

/**
 * Pure pre-check of a vendor payment (P6, Step 07 §5-§6, Step 08 §9) with the arithmetic of
 * `record_vendor_payment`: every allocation relieves accounts payable at the value the bill carries (a partial
 * payment takes a proportional share of the remaining base value and the payment that clears a bill takes
 * exactly what is left), the cash side is converted at the payment's own rate, and the difference is the
 * exchange gain or loss. The payment always equals the sum of its allocations: vendor advances and credits are
 * not part of this phase (DECISIONS 77). The database recomputes and re-validates everything under the bill
 * locks; this only gives the person an early answer.
 */

export interface VendorAllocationDraft {
  billId: string;
  /** What this payment settles on the bill, in the bill (= paying account) currency. */
  amount: string;
  /** Still outstanding on the bill before this payment, in the bill currency. */
  outstanding: string;
  /** The same outstanding in the Entity base currency. */
  outstandingBase: string;
}

export interface VendorPaymentDraft {
  baseCurrency: string;
  /** Currency of the paying account (and of every allocated bill). */
  accountCurrency: string;
  amount: string;
  /** Required exactly when the account is not in the base currency. */
  rate?: string;
  allocations: readonly VendorAllocationDraft[];
}

export interface VendorPaymentFigures {
  allocated: Decimal;
  /** The whole payment in base currency, as the cash movement will book it. */
  cashBase: Decimal;
  /** Accounts-payable debit per allocation, in the same order as the drafts. */
  payableBase: Decimal[];
  /** sum(payableBase) - cashBase: positive = gain (paid less base value than was booked), negative = loss. */
  fxDifference: Decimal;
}

export type VendorPaymentProblem =
  | "amount_invalid"
  | "too_many_decimals"
  | "rate_required"
  | "rate_not_allowed"
  | "rate_invalid"
  | "no_allocations"
  | "too_many_allocations"
  | "duplicate_bill"
  | "allocation_invalid"
  | "allocation_exceeds_outstanding"
  | "allocations_differ_from_payment"
  | "too_small"
  | "fx_difference_too_large";

export type VendorPaymentCheck =
  | { ok: true; figures: VendorPaymentFigures }
  | { ok: false; problem: VendorPaymentProblem; allocation?: number };

const AMOUNT_LIMIT = Decimal.parse("10000000000000"); // 10^13
const RATE_LIMIT = Decimal.parse("10000000000"); // 10^10
const RATE_SCALE = 10;
const MAX_ALLOCATIONS = 100;

export function checkVendorPayment(draft: VendorPaymentDraft): VendorPaymentCheck {
  const fail = (problem: VendorPaymentProblem, allocation?: number): VendorPaymentCheck => ({
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

  if (draft.allocations.length === 0) return fail("no_allocations");
  if (draft.allocations.length > MAX_ALLOCATIONS) return fail("too_many_allocations");

  const seen = new Set<string>();
  const allocated: Decimal[] = [];
  const payable: Decimal[] = [];
  for (const [index, item] of draft.allocations.entries()) {
    if (seen.has(item.billId)) return fail("duplicate_bill", index);
    seen.add(item.billId);
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
    payable.push(prorateRemaining(outstanding, outstandingBase, part, baseScale));
  }

  const allocatedTotal = sumDecimals(allocated);
  if (!allocatedTotal.eq(amount)) return fail("allocations_differ_from_payment");

  const cashBase = rate === null ? amount : convertAmount(amount, rate, draft.baseCurrency);
  if (!cashBase.isPositive()) return fail("too_small");
  const fxDifference = sumDecimals(payable).sub(cashBase);
  // The database refuses an exchange difference above 20% of the cash paid (a mistyped rate, not FX).
  if (fxDifference.abs().mul(Decimal.fromInteger(5)).cmp(cashBase) > 0) {
    return fail("fx_difference_too_large");
  }

  return {
    ok: true,
    figures: { allocated: allocatedTotal, cashBase, payableBase: payable, fxDifference },
  };
}

const MESSAGES: Readonly<Record<VendorPaymentProblem, string>> = {
  amount_invalid: "Jumlah pembayaran harus angka lebih dari nol.",
  too_many_decimals: "Jumlah melebihi desimal yang diizinkan mata uang akun pembayar.",
  rate_required: "Kurs wajib diisi untuk akun bermata uang asing.",
  rate_not_allowed: "Kurs tidak diisi untuk akun bermata uang dasar.",
  rate_invalid: "Kurs tidak valid (angka positif, maks. 10 desimal).",
  no_allocations: "Pilih minimal satu tagihan yang dibayar.",
  too_many_allocations: "Satu pembayaran maksimal untuk 100 tagihan.",
  duplicate_bill: "Satu tagihan hanya boleh muncul sekali dalam alokasi.",
  allocation_invalid: "Alokasi ke tagihan tidak valid.",
  allocation_exceeds_outstanding: "Alokasi melebihi sisa tagihan tersebut.",
  allocations_differ_from_payment:
    "Jumlah pembayaran harus sama dengan total alokasi. Uang muka vendor belum didukung.",
  too_small: "Jumlah terlalu kecil untuk dibukukan dalam mata uang dasar.",
  fx_difference_too_large: "Selisih kurs melebihi 20% dari jumlah; periksa kembali kurs.",
};

export function vendorPaymentProblemMessage(
  problem: VendorPaymentProblem,
  allocation?: number,
): string {
  return allocation === undefined
    ? MESSAGES[problem]
    : `Alokasi ${allocation + 1}: ${MESSAGES[problem]}`;
}

export type PaymentDateProblem = "future" | "before_bill" | "before_reversal";

/**
 * The date rules of a payment on one or more bills (the database applies them too): not in the future, not
 * before the bill date, and not before a reversal already booked on the same bill, because between the two
 * dates the earlier payment and the new one would both count and the payable would go negative.
 */
export function checkPaymentDate(
  paymentDate: string,
  today: string,
  bills: readonly { billDate: string; lastReversedDate?: string | null }[],
): PaymentDateProblem | null {
  if (paymentDate > today) return "future";
  for (const bill of bills) {
    if (paymentDate < bill.billDate) return "before_bill";
    if (bill.lastReversedDate && paymentDate < bill.lastReversedDate) return "before_reversal";
  }
  return null;
}

const DATE_MESSAGES: Readonly<Record<PaymentDateProblem, string>> = {
  future: "Tanggal pembayaran tidak boleh di masa depan.",
  before_bill: "Tanggal pembayaran tidak boleh sebelum tanggal tagihan.",
  before_reversal:
    "Tagihan ini pernah dibatalkan pembayarannya; tanggal pembayaran baru tidak boleh sebelum tanggal pembatalan itu.",
};

export function paymentDateProblemMessage(problem: PaymentDateProblem): string {
  return DATE_MESSAGES[problem];
}
