/**
 * Income entered without an invoice ("Catat Pendapatan", decision 350): the month's totals and the words the
 * form uses to say what an entry does. Pure, so the screen and the tests share one rule.
 */

export interface IncomeEntryAmount {
  status: "recorded" | "reversed";
  amount: string;
  in_turnover: boolean;
}

export interface IncomeSummary {
  /** Entries still standing (a reversed entry is shown in the list but never counted). */
  count: number;
  total: string;
  /** Business income: the part that counts toward the PPh Final 0,5% base and the yearly ceiling. */
  turnover: string;
  /** Income outside the business (interest, dividend, ...): booked, but not in the PPh Final base. */
  outside: string;
}

const SCALE = 4;

/** "1234.5" -> 12345000 (four decimals, the scale money is stored with). */
function toUnits(text: string): bigint {
  const [whole = "0", fraction = ""] = text.trim().split(".");
  const padded = (fraction + "0".repeat(SCALE)).slice(0, SCALE);
  return BigInt(whole || "0") * BigInt(10 ** SCALE) + BigInt(padded || "0");
}

function fromUnits(units: bigint): string {
  const base = BigInt(10 ** SCALE);
  const whole = units / base;
  const fraction = (units % base).toString().padStart(SCALE, "0").replace(/0+$/, "");
  return fraction ? `${whole}.${fraction}` : whole.toString();
}

export function summarizeIncome(rows: readonly IncomeEntryAmount[]): IncomeSummary {
  let turnover = BigInt(0);
  let outside = BigInt(0);
  let count = 0;
  for (const row of rows) {
    if (row.status !== "recorded") continue;
    count += 1;
    if (row.in_turnover) turnover += toUnits(row.amount);
    else outside += toUnits(row.amount);
  }
  return {
    count,
    total: fromUnits(turnover + outside),
    turnover: fromUnits(turnover),
    outside: fromUnits(outside),
  };
}

/**
 * One sentence the form and the detail page show about the tax side of an income category. For a Personal book the
 * category's tag (decision 365) says which part of the personal tax it belongs to; for a company book (`role`
 * undefined) the old rule applies: business income is in the final-tax base, other income is not.
 */
export function incomeTaxNote(inTurnover: boolean, role?: string | null): string {
  if (role === "freelance") {
    return "Pendapatan jasa: masuk hitungan PPh Progresif (penghasilan neto) di menu Pajak Pribadi.";
  }
  if (role === "company_payout") {
    return "Uang dari PT Anda: cukup catat uang masuknya. Penghasilan dan pajak yang dipotong dibaca otomatis dari dokumen PT, jadi tidak perlu diisi lagi di sini.";
  }
  if (role === "umkm_business") {
    return "Penjualan usaha: ikut dasar PPh Final 0,5% dan batas omzet tahunan.";
  }
  if (role === null) {
    return "Bukan pendapatan usaha atau jasa: tercatat di laporan, tetapi tidak masuk hitungan Pajak Pribadi.";
  }
  return inTurnover
    ? "Dihitung sebagai pendapatan usaha: ikut dasar PPh Final 0,5% dan batas omzet tahunan."
    : "Pendapatan di luar usaha: tercatat di laporan, tetapi tidak ikut dasar PPh Final 0,5%.";
}

/** Gross income from what reached the account plus the tax the client withheld ("1000", "50" -> "1050"). */
export function grossFromReceived(received: string, withheld: string): string {
  return fromUnits(toUnits(received) + toUnits(withheld || "0"));
}

/** "2026-10" -> first and last day of the month, as ISO dates; null when the text is not a month. */
export function monthRange(month: string): { from: string; to: string } | null {
  const match = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(month);
  if (!match) return null;
  const year = Number(match[1]);
  const mon = Number(match[2]);
  const last = new Date(Date.UTC(year, mon, 0)).getUTCDate();
  return {
    from: `${match[1]}-${match[2]}-01`,
    to: `${match[1]}-${match[2]}-${String(last).padStart(2, "0")}`,
  };
}
