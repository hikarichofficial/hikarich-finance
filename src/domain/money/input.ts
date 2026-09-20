/**
 * Reads an amount typed by a person in Indonesian style ("1.500.000", "1.500.000,50", "Rp 250000") into the
 * plain decimal text the rest of the system uses ("1500000", "1500000.50", "250000"). It never guesses across
 * a real ambiguity: anything it cannot read with certainty returns null, and the person is asked again.
 *
 * Rules: "," is the decimal mark when present; a lone "." followed by exactly three digits is a thousands
 * mark ("1.500" is 1500) while any other lone "." is a decimal mark ("1.5", "1.25"); with both marks the
 * last one is the decimal mark; several "." are thousands marks.
 */
export function parseMoneyInput(raw: string): string | null {
  const text = raw
    .trim()
    .replace(/^(rp|idr)\.?\s*/i, "")
    .replace(/\s+/g, "");
  if (!/^\d[\d.,]*$/.test(text)) return null;

  const lastDot = text.lastIndexOf(".");
  const lastComma = text.lastIndexOf(",");
  let decimalMark: "." | "," | null = null;
  if (lastDot >= 0 && lastComma >= 0) {
    decimalMark = lastDot > lastComma ? "." : ",";
  } else if (lastComma >= 0) {
    decimalMark = ",";
  } else if (lastDot >= 0) {
    const dots = text.split(".").length - 1;
    const after = text.length - lastDot - 1;
    decimalMark = dots === 1 && after !== 3 ? "." : null;
  }

  const thousandsMark = decimalMark === "." ? "," : decimalMark === "," ? "." : ".";
  const decimalAt = decimalMark === null ? -1 : text.lastIndexOf(decimalMark);
  const wholePart = decimalAt >= 0 ? text.slice(0, decimalAt) : text;
  const fractionPart = decimalAt >= 0 ? text.slice(decimalAt + 1) : "";

  if (fractionPart !== "" && !/^\d+$/.test(fractionPart)) return null;
  if (decimalAt >= 0 && fractionPart === "") return null;
  // The whole part may only contain digits and thousands marks, in proper groups of three after the first.
  const groups = wholePart.split(thousandsMark);
  if (groups.some((group) => !/^\d+$/.test(group))) return null;
  if (groups.length > 1 && (groups[0].length > 3 || groups.slice(1).some((g) => g.length !== 3))) {
    return null;
  }
  // "0.500" is not five hundred with a leading zero: a first group starting with 0 cannot be followed by more groups.
  if (groups.length > 1 && groups[0].startsWith("0")) return null;
  const whole = groups.join("").replace(/^0+(?=\d)/, "");
  return fractionPart === "" ? whole : `${whole}.${fractionPart}`;
}
