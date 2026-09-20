import { Decimal } from "@/domain/money/decimal";
import { convertAmount, currencyScale } from "@/domain/money/currency";

/**
 * Pure pre-check of an internal transfer (P4, Step 15 §8) before it is sent to the database. The database
 * (`app_private.transfer_figures`) recomputes and re-validates everything inside the confirmation
 * transaction; this only gives the person an early, readable answer, with exactly the same arithmetic.
 *
 * A transfer moves money between two of the Entity's own accounts. It never creates revenue or expense;
 * only a bank fee (expense) and an FX difference (FX gain/loss) can reach the profit and loss.
 */

export interface TransferDraft {
  baseCurrency: string;
  fromCurrency: string;
  toCurrency: string;
  amountOut: string;
  /** Required when the two accounts use different currencies; equals amountOut otherwise. */
  amountIn?: string;
  fee?: string;
  /** Required exactly when the source account is not in the base currency. */
  rateOut?: string;
  /** Required exactly when the destination account is not in the base currency. */
  rateIn?: string;
}

export interface TransferFigures {
  amountIn: Decimal;
  baseOut: Decimal;
  baseIn: Decimal;
  baseFee: Decimal;
  /** baseIn - baseOut: positive = FX gain, negative = FX loss. */
  fxDifference: Decimal;
}

export type TransferProblem =
  | "amount_invalid"
  | "fee_invalid"
  | "amount_in_required"
  | "amount_in_differs"
  | "too_many_decimals"
  | "rate_required"
  | "rate_not_allowed"
  | "rate_invalid"
  | "rates_differ"
  | "too_small"
  | "fx_difference_too_large";

export type TransferCheck =
  { ok: true; figures: TransferFigures } | { ok: false; problem: TransferProblem };

const MAX_AMOUNT = Decimal.parse("10000000000000000"); // 10^16, the database's ceiling
const RATE_SCALE = 10;

function positive(text: string | undefined): Decimal | null {
  const value = Decimal.tryParse(text);
  return value && value.isPositive() && value.cmp(MAX_AMOUNT) < 0 ? value : null;
}

export function checkTransfer(draft: TransferDraft): TransferCheck {
  const fail = (problem: TransferProblem): TransferCheck => ({ ok: false, problem });
  const fromScale = currencyScale(draft.fromCurrency);
  const toScale = currencyScale(draft.toCurrency);
  const sameCurrency = draft.fromCurrency === draft.toCurrency;

  const out = positive(draft.amountOut);
  if (!out) return fail("amount_invalid");
  const fee =
    draft.fee === undefined || draft.fee === "" ? Decimal.zero() : Decimal.tryParse(draft.fee);
  if (!fee || fee.isNegative() || fee.cmp(MAX_AMOUNT) >= 0) return fail("fee_invalid");

  let received: Decimal;
  if (draft.amountIn === undefined || draft.amountIn === "") {
    if (!sameCurrency) return fail("amount_in_required");
    received = out;
  } else {
    const parsed = positive(draft.amountIn);
    if (!parsed) return fail("amount_invalid");
    received = parsed;
  }
  if (sameCurrency && !received.eq(out)) return fail("amount_in_differs");
  if (!out.fitsScale(fromScale) || !fee.fitsScale(fromScale) || !received.fitsScale(toScale)) {
    return fail("too_many_decimals");
  }

  const rateFor = (
    rate: string | undefined,
    isBase: boolean,
  ): Decimal | null | "missing" | "extra" => {
    const present = rate !== undefined && rate !== "";
    if (isBase) return present ? "extra" : null;
    if (!present) return "missing";
    const parsed = Decimal.tryParse(rate);
    return parsed && parsed.isPositive() && parsed.fitsScale(RATE_SCALE) ? parsed : "missing";
  };
  const rateOut = rateFor(draft.rateOut, draft.fromCurrency === draft.baseCurrency);
  const rateIn = rateFor(draft.rateIn, draft.toCurrency === draft.baseCurrency);
  if (rateOut === "extra" || rateIn === "extra") return fail("rate_not_allowed");
  if (rateOut === "missing" || rateIn === "missing") {
    const supplied = [draft.rateOut, draft.rateIn].some((r) => r !== undefined && r !== "");
    return fail(supplied ? "rate_invalid" : "rate_required");
  }

  // Between two accounts of the same foreign currency one rate applies: a transfer never invents an exchange gain.
  if (
    draft.fromCurrency === draft.toCurrency &&
    draft.fromCurrency !== draft.baseCurrency &&
    rateOut !== null &&
    rateIn !== null &&
    !(rateOut as Decimal).eq(rateIn as Decimal)
  ) {
    return fail("rates_differ");
  }
  const inBase = (amount: Decimal, currency: string, rate: Decimal | null): Decimal =>
    currency === draft.baseCurrency || rate === null
      ? amount
      : convertAmount(amount, rate, draft.baseCurrency);
  const baseOut = inBase(out, draft.fromCurrency, rateOut);
  const baseFee = inBase(fee, draft.fromCurrency, rateOut);
  const baseIn = inBase(received, draft.toCurrency, rateIn);
  if (
    !baseOut.isPositive() ||
    !baseIn.isPositive() ||
    (fee.isPositive() && !baseFee.isPositive())
  ) {
    return fail("too_small");
  }
  // The database refuses a base difference above 20% of the amount sent (a mistyped rate, not FX).
  if (baseIn.sub(baseOut).abs().mul(Decimal.fromInteger(5)).cmp(baseOut) > 0) {
    return fail("fx_difference_too_large");
  }
  return {
    ok: true,
    figures: { amountIn: received, baseOut, baseIn, baseFee, fxDifference: baseIn.sub(baseOut) },
  };
}

const MESSAGES: Readonly<Record<TransferProblem, string>> = {
  amount_invalid: "Jumlah transfer harus angka lebih dari nol.",
  fee_invalid: "Biaya harus nol atau angka positif.",
  amount_in_required: "Jumlah yang diterima wajib diisi untuk transfer antar mata uang.",
  amount_in_differs: "Untuk mata uang yang sama, jumlah diterima harus sama dengan jumlah dikirim.",
  too_many_decimals: "Jumlah melebihi desimal yang diizinkan mata uang tersebut.",
  rate_required: "Kurs wajib diisi untuk akun bermata uang asing.",
  rate_not_allowed: "Kurs tidak diisi untuk akun bermata uang dasar.",
  rate_invalid: "Kurs tidak valid (angka positif, maks. 10 desimal).",
  rates_differ: "Untuk dua akun bermata uang asing yang sama, gunakan satu kurs yang sama.",
  too_small: "Jumlah atau biaya terlalu kecil untuk dibukukan dalam mata uang dasar.",
  fx_difference_too_large: "Selisih kurs melebihi 20% dari jumlah; periksa kembali kurs.",
};

export function transferProblemMessage(problem: TransferProblem): string {
  return MESSAGES[problem];
}
