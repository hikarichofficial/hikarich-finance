import { Decimal } from "@/domain/money/decimal";

/**
 * Expense lines are entered as ONE amount "as on the receipt" (OWNER, 8 October 2026: a food purchase should
 * not have to be split per menu item). The amount is the line's unit price with quantity 1, so the purchase
 * RPCs are unchanged. When a line that was entered as quantity x unit price (an older draft, or the detail
 * switch) is shown as one amount, it becomes quantity x unit price. Anything that is not a plain decimal is
 * kept as the unit price untouched.
 */
export function foldToAmount(quantity: string, unitPrice: string): string {
  const q = quantity.trim().replace(",", ".");
  const price = unitPrice.trim();
  if (q === "" || price === "") return price;
  const qd = Decimal.tryParse(q);
  const pd = Decimal.tryParse(price);
  if (qd === null || pd === null) return price;
  if (qd.eq(Decimal.fromInteger(1))) return price;
  return trimZeros(pd.mul(qd).toString());
}

function trimZeros(text: string): string {
  return text.includes(".") ? text.replace(/0+$/, "").replace(/\.$/, "") : text;
}

/** True when some line has a quantity other than 1: such a draft opens in the detailed (quantity x price) mode. */
export function hasDetailedQuantity(lines: readonly { quantity?: unknown }[]): boolean {
  return lines.some((line) => {
    if (line.quantity == null) return false;
    const q = Decimal.tryParse(String(line.quantity));
    return q !== null && !q.eq(Decimal.fromInteger(1));
  });
}
