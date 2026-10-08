/**
 * "Harga di struk sudah termasuk PPN" (OWNER, 8 October 2026): the person types the total printed on the
 * receipt and ticks the box; the form splits it into the price before VAT (the base for withholding tax) and
 * the VAT itself, so no tax is ever computed from the receipt total. The standard VAT rate in force is 11%
 * of the price (rule `vat_standard`); the split here only fills two ordinary fields and the tax engine still
 * checks and decides everything at posting time.
 */
export const VAT_RATE_PERCENT = 11;

const ZERO = BigInt(0);
const TWO = BigInt(2);
const HUNDRED = BigInt(100);

/**
 * Splits a VAT-inclusive total ("397000", "1500.5") into the price before VAT and the VAT. Whole-rupiah totals
 * stay whole; the two parts always add up to the total exactly. Returns null for an empty or unreadable text.
 */
export function splitVatInclusive(totalText: string): { net: string; vat: string } | null {
  const text = totalText.trim();
  if (!/^\d+(\.\d{0,4})?$/.test(text) || text.length > 20) return null;
  const [whole = "0", fraction = ""] = text.split(".");
  const scale = fraction.length;
  const units = BigInt(whole + fraction.padEnd(scale, "0"));
  if (units === ZERO) return null;
  const denominator = BigInt(100 + VAT_RATE_PERCENT);
  // net = total x 100 / 111, rounded half up, in the same number of decimals as the total.
  const net = (units * HUNDRED + denominator / TWO) / denominator;
  const vat = units - net;
  return { net: show(net, scale), vat: show(vat, scale) };
}

function show(units: bigint, scale: number): string {
  if (scale === 0) return units.toString();
  const digits = units.toString().padStart(scale + 1, "0");
  const whole = digits.slice(0, -scale);
  const fraction = digits.slice(-scale).replace(/0+$/, "");
  return fraction === "" ? whole : `${whole}.${fraction}`;
}
