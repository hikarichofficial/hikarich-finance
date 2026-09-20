import { Decimal } from "@/domain/money/decimal";
import { currencyScale } from "@/domain/money/currency";

/**
 * Exact invoice-line arithmetic (P5, Step 08 §5, Step 04 §14) with the same rules as the database
 * (`app_private.invoice_prepare_lines`), so a form can show the customer-facing figures before anything is
 * sent. The database recomputes every line and total inside the transaction and never trusts a total from
 * the caller; this is only an early, readable answer.
 *
 * - quantity x unit price rounds ONCE per line, half-up, to the invoice currency's minor unit;
 * - a percentage discount rounds once, half-up; a fixed discount must already fit the currency and can never
 *   exceed the line;
 * - tax is not calculated here: it is refused until the tax phase (DECISIONS 65), so a line total is
 *   subtotal minus discount.
 */

export type DiscountType = "none" | "percent" | "fixed";

export interface InvoiceLineDraft {
  description: string;
  /** Defaults to 1. Positive, at most 4 decimals. */
  quantity?: string;
  /** Required (the screen fills it from the product's default price when the person leaves it empty). */
  unitPrice?: string;
  discountType?: DiscountType;
  discountValue?: string;
}

export interface PreparedLine {
  lineNo: number;
  description: string;
  quantity: Decimal;
  unitPrice: Decimal;
  discountType: DiscountType;
  discountValue: Decimal;
  lineSubtotal: Decimal;
  discountAmount: Decimal;
  lineTotal: Decimal;
}

export interface PreparedInvoice {
  lines: PreparedLine[];
  subtotal: Decimal;
  discountTotal: Decimal;
  total: Decimal;
}

export type InvoiceLineProblem =
  | "too_many_lines"
  | "description_required"
  | "quantity_invalid"
  | "price_required"
  | "price_invalid"
  | "amount_too_large"
  | "discount_type_invalid"
  | "discount_without_type"
  | "discount_invalid"
  | "percent_over_100"
  | "fixed_too_precise"
  | "discount_exceeds_line";

export type InvoiceCheck =
  | { ok: true; invoice: PreparedInvoice }
  | { ok: false; problem: InvoiceLineProblem; line?: number };

export const MAX_INVOICE_LINES = 200;
export const MAX_DESCRIPTION_LENGTH = 500;

const QUANTITY_LIMIT = Decimal.parse("1000000000"); // 10^9
const PRICE_LIMIT = Decimal.parse("1000000000000"); // 10^12
const LINE_LIMIT = Decimal.parse("10000000000000"); // 10^13
const HUNDRED = Decimal.fromInteger(100);
const FIELD_SCALE = 4;

function text(value: string | undefined): string | undefined {
  const trimmed = value?.trim();
  return trimmed === undefined || trimmed === "" ? undefined : trimmed;
}

/** value / 100, exact (a shift of the decimal point). */
function percentOf(amount: Decimal, percent: Decimal): Decimal {
  const product = amount.mul(percent);
  return Decimal.fromUnits(product.units, product.scale + 2);
}

export function prepareInvoiceLines(
  currency: string,
  lines: readonly InvoiceLineDraft[],
): InvoiceCheck {
  const scale = currencyScale(currency);
  if (lines.length > MAX_INVOICE_LINES) return { ok: false, problem: "too_many_lines" };

  const prepared: PreparedLine[] = [];
  let subtotal = Decimal.zero(scale);
  let discountTotal = Decimal.zero(scale);

  for (const [index, draft] of lines.entries()) {
    const lineNo = index + 1;
    const fail = (problem: InvoiceLineProblem): InvoiceCheck => ({
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
    const lineSubtotal = quantity.mul(unitPrice).round(scale, "half_up");
    if (lineSubtotal.cmp(LINE_LIMIT) >= 0) return fail("amount_too_large");

    const discountType = draft.discountType ?? "none";
    if (discountType !== "none" && discountType !== "percent" && discountType !== "fixed") {
      return fail("discount_type_invalid");
    }
    const valueText = text(draft.discountValue);
    const parsedValue = valueText === undefined ? Decimal.zero() : Decimal.tryParse(valueText);
    if (discountType === "none") {
      if (parsedValue && !parsedValue.isZero()) return fail("discount_without_type");
      if (!parsedValue) return fail("discount_invalid");
    }
    const discountValue = discountType === "none" ? Decimal.zero() : parsedValue;
    if (!discountValue || discountValue.isNegative() || !discountValue.fitsScale(FIELD_SCALE)) {
      return fail("discount_invalid");
    }

    let discountAmount = Decimal.zero(scale);
    if (discountType === "percent") {
      if (discountValue.cmp(HUNDRED) > 0) return fail("percent_over_100");
      discountAmount = percentOf(lineSubtotal, discountValue).round(scale, "half_up");
    } else if (discountType === "fixed") {
      if (!discountValue.fitsScale(scale)) return fail("fixed_too_precise");
      if (discountValue.cmp(lineSubtotal) > 0) return fail("discount_exceeds_line");
      discountAmount = discountValue.round(scale, "half_up");
    }

    const lineTotal = lineSubtotal.sub(discountAmount);
    subtotal = subtotal.add(lineSubtotal);
    discountTotal = discountTotal.add(discountAmount);
    prepared.push({
      lineNo,
      description,
      quantity,
      unitPrice,
      discountType,
      discountValue,
      lineSubtotal,
      discountAmount,
      lineTotal,
    });
  }

  return {
    ok: true,
    invoice: { lines: prepared, subtotal, discountTotal, total: subtotal.sub(discountTotal) },
  };
}

const MESSAGES: Readonly<Record<InvoiceLineProblem, string>> = {
  too_many_lines: "Satu faktur maksimal 200 baris.",
  description_required: "Deskripsi baris wajib diisi (maksimal 500 karakter).",
  quantity_invalid: "Kuantitas harus lebih dari nol dengan maksimal 4 desimal.",
  price_required: "Harga satuan wajib diisi.",
  price_invalid: "Harga satuan tidak boleh negatif dan maksimal 4 desimal.",
  amount_too_large: "Jumlah baris terlalu besar.",
  discount_type_invalid: "Jenis diskon harus tanpa diskon, persen, atau nominal.",
  discount_without_type: "Nilai diskon diisi tetapi jenis diskon belum dipilih.",
  discount_invalid: "Diskon tidak boleh negatif dan maksimal 4 desimal.",
  percent_over_100: "Diskon persen tidak boleh lebih dari 100.",
  fixed_too_precise: "Diskon nominal melebihi desimal yang diizinkan mata uang faktur.",
  discount_exceeds_line: "Diskon melebihi jumlah baris.",
};

export function invoiceProblemMessage(problem: InvoiceLineProblem, line?: number): string {
  return line === undefined ? MESSAGES[problem] : `Baris ${line}: ${MESSAGES[problem]}`;
}
