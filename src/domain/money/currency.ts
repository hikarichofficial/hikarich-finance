import { Decimal, DecimalError, type RoundingMode } from "./decimal";

/**
 * Minor-unit digits per currency, mirroring the ISO 4217 reference table in `public.currencies`
 * (the database is authoritative; this copy lets the browser/server layer validate before a round trip).
 * Adding a currency means adding it to the database reference table first.
 */
export const CURRENCY_MINOR_UNITS: Readonly<Record<string, number>> = {
  IDR: 2,
  USD: 2,
  EUR: 2,
  SGD: 2,
  MYR: 2,
  AUD: 2,
  GBP: 2,
  JPY: 0,
  CNY: 2,
  SAR: 2,
};

export function isKnownCurrency(code: string): boolean {
  return Object.prototype.hasOwnProperty.call(CURRENCY_MINOR_UNITS, code);
}

export function currencyScale(code: string): number {
  if (!isKnownCurrency(code)) throw new DecimalError(`Unknown currency ${code}`);
  return CURRENCY_MINOR_UNITS[code];
}

/**
 * Converts an original-currency amount into the target (normally Entity base) currency and rounds once,
 * with the target currency's own minor unit. Mirrors `app_private.convert_amount`. The caller keeps the
 * original amount and the rate alongside the result (Step 04 §14).
 */
export function convertAmount(
  amount: Decimal,
  rate: Decimal,
  targetCurrency: string,
  mode: RoundingMode = "half_up",
): Decimal {
  if (!rate.isPositive()) throw new DecimalError("Exchange rate must be positive");
  return amount.mul(rate).round(currencyScale(targetCurrency), mode);
}
