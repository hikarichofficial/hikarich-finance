import { Decimal } from "@/domain/money/decimal";
import { currencyScale } from "@/domain/money/currency";

/**
 * Exact bill and expense line arithmetic (P6, Step 08 §5, Step 04 §14) with the same rules as the database
 * (`app_private.purchase_prepare_lines`), so a form can show the figures before anything is sent. The database
 * recomputes every line and total inside the transaction and never trusts a total from the caller; this is only
 * an early, readable answer.
 *
 * - quantity x unit price rounds ONCE per line, half-up, to the document currency's minor unit;
 * - a line must come to more than zero after rounding, and there are no discounts on purchases (DECISIONS 78);
 * - tax is not calculated here: it is refused until the tax phase, so a line total is quantity x unit price.
 */

export type PurchaseTreatment = "expense" | "asset" | "prepaid";

export const PURCHASE_TREATMENTS: readonly PurchaseTreatment[] = ["expense", "asset", "prepaid"];

export const PURCHASE_TREATMENT_LABELS: Readonly<Record<PurchaseTreatment, string>> = {
  expense: "Biaya",
  asset: "Aset tetap",
  prepaid: "Dibayar di muka",
};

export interface PurchaseLineDraft {
  description: string;
  /** Defaults to 1. Positive, at most 4 decimals. */
  quantity?: string;
  /** Required. */
  unitPrice?: string;
  /** Defaults to `expense`. */
  treatment?: string;
}

export interface PreparedPurchaseLine {
  lineNo: number;
  description: string;
  quantity: Decimal;
  unitPrice: Decimal;
  treatment: PurchaseTreatment;
  lineTotal: Decimal;
}

export interface PreparedPurchase {
  lines: PreparedPurchaseLine[];
  total: Decimal;
}

export type PurchaseLineProblem =
  | "too_many_lines"
  | "description_required"
  | "quantity_invalid"
  | "price_required"
  | "price_invalid"
  | "amount_zero"
  | "amount_too_large"
  | "treatment_invalid";

export type PurchaseCheck =
  | { ok: true; purchase: PreparedPurchase }
  | { ok: false; problem: PurchaseLineProblem; line?: number };

export const MAX_PURCHASE_LINES = 200;
export const MAX_DESCRIPTION_LENGTH = 500;

const QUANTITY_LIMIT = Decimal.parse("1000000000"); // 10^9
const PRICE_LIMIT = Decimal.parse("1000000000000"); // 10^12
const LINE_LIMIT = Decimal.parse("10000000000000"); // 10^13
const FIELD_SCALE = 4;

function text(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed === undefined || trimmed === "" ? undefined : trimmed;
}

export function preparePurchaseLines(
  currency: string,
  lines: readonly PurchaseLineDraft[],
): PurchaseCheck {
  const scale = currencyScale(currency);
  if (lines.length > MAX_PURCHASE_LINES) return { ok: false, problem: "too_many_lines" };

  const prepared: PreparedPurchaseLine[] = [];
  let total = Decimal.zero(scale);

  for (const [index, draft] of lines.entries()) {
    const lineNo = index + 1;
    const fail = (problem: PurchaseLineProblem): PurchaseCheck => ({
      ok: false,
      problem,
      line: lineNo,
    });

    const description = text(draft.description);
    if (!description || description.length > MAX_DESCRIPTION_LENGTH) {
      return fail("description_required");
    }

    const quantity = Decimal.tryParse(text(draft.quantity) ?? "1");
    if (
      !quantity ||
      !quantity.isPositive() ||
      quantity.cmp(QUANTITY_LIMIT) >= 0 ||
      !quantity.fitsScale(FIELD_SCALE)
    ) {
      return fail("quantity_invalid");
    }

    const priceText = text(draft.unitPrice);
    if (priceText === undefined) return fail("price_required");
    const unitPrice = Decimal.tryParse(priceText);
    if (
      !unitPrice ||
      unitPrice.isNegative() ||
      unitPrice.cmp(PRICE_LIMIT) >= 0 ||
      !unitPrice.fitsScale(FIELD_SCALE)
    ) {
      return fail("price_invalid");
    }

    const lineTotal = quantity.mul(unitPrice).round(scale, "half_up");
    if (!lineTotal.isPositive()) return fail("amount_zero");
    if (lineTotal.cmp(LINE_LIMIT) >= 0) return fail("amount_too_large");

    const treatment = text(draft.treatment) ?? "expense";
    if (!isTreatment(treatment)) return fail("treatment_invalid");

    total = total.add(lineTotal);
    prepared.push({ lineNo, description, quantity, unitPrice, treatment, lineTotal });
  }

  return { ok: true, purchase: { lines: prepared, total } };
}

function isTreatment(value: string): value is PurchaseTreatment {
  return (PURCHASE_TREATMENTS as readonly string[]).includes(value);
}

const MESSAGES: Readonly<Record<PurchaseLineProblem, string>> = {
  too_many_lines: "Satu dokumen maksimal 200 baris.",
  description_required: "Deskripsi baris wajib diisi (maksimal 500 karakter).",
  quantity_invalid: "Kuantitas harus lebih dari nol dengan maksimal 4 desimal.",
  price_required: "Harga satuan wajib diisi.",
  price_invalid: "Harga satuan tidak boleh negatif dan maksimal 4 desimal.",
  amount_zero: "Jumlah baris harus lebih dari nol setelah pembulatan.",
  amount_too_large: "Jumlah baris terlalu besar.",
  treatment_invalid: "Perlakuan baris harus biaya, aset tetap, atau dibayar di muka.",
};

export function purchaseProblemMessage(problem: PurchaseLineProblem, line?: number): string {
  return line === undefined ? MESSAGES[problem] : `Baris ${line}: ${MESSAGES[problem]}`;
}
