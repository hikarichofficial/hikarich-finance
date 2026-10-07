/** Pure helpers of the "Rekening Koran" screen (decision 326): the month and page from the address, and the
 * page numbers to show under a long statement. */

export const STATEMENT_PAGE_SIZE = 20;

/** "2026-10" -> "2026-10-01". Anything else -> null (the database then uses the current month). */
export function parseStatementMonth(value: string | undefined): string | null {
  if (!value || !/^\d{4}-(0[1-9]|1[0-2])$/.test(value)) return null;
  return `${value}-01`;
}

/** The page number (1-based) from the address; anything invalid is page 1. */
export function parseStatementPage(value: string | undefined): number {
  const parsed = Number.parseInt(value ?? "", 10);
  return Number.isFinite(parsed) && parsed >= 1 && parsed <= 100000 ? parsed : 1;
}

/** Page numbers to draw: always the first and last, and a few around the current page; `null` is a gap. */
export function pageWindow(current: number, totalPages: number): (number | null)[] {
  if (totalPages <= 7) return Array.from({ length: totalPages }, (_, i) => i + 1);
  const wanted = new Set([1, totalPages, current - 1, current, current + 1]);
  const pages = [...wanted].filter((p) => p >= 1 && p <= totalPages).sort((a, b) => a - b);
  const out: (number | null)[] = [];
  pages.forEach((page, index) => {
    if (index > 0 && page - pages[index - 1] > 1) out.push(null);
    out.push(page);
  });
  return out;
}

const MONTH_NAMES = [
  "Januari",
  "Februari",
  "Maret",
  "April",
  "Mei",
  "Juni",
  "Juli",
  "Agustus",
  "September",
  "Oktober",
  "November",
  "Desember",
];

/** "2026-10-01" -> "Oktober 2026". */
export function monthLabel(isoDate: string): string {
  const [year, month] = isoDate.split("-");
  return `${MONTH_NAMES[Number(month) - 1]} ${year}`;
}

/** The year from the address ("2026"); anything invalid falls back to `fallback` (the current year). */
export function parseStatementYear(value: string | undefined, fallback: number): number {
  const parsed = /^\d{4}$/.test(value ?? "") ? Number.parseInt(value ?? "", 10) : NaN;
  return Number.isFinite(parsed) && parsed >= 2000 && parsed <= 2100 ? parsed : fallback;
}

/** "2026-10" moved by `delta` months ("2026-12" + 1 = "2027-01"). */
export function shiftMonth(monthKey: string, delta: number): string {
  const [year, month] = monthKey.split("-").map(Number);
  const index = year * 12 + (month - 1) + delta;
  const nextYear = Math.floor(index / 12);
  return `${nextYear}-${String((index % 12) + 1).padStart(2, "0")}`;
}

/** The years to offer in the year picker: a few before and after, always including the chosen one. */
export function yearOptions(selected: number, currentYear: number): number[] {
  const first = Math.min(selected, currentYear - 5);
  const last = Math.max(selected, currentYear + 1);
  return Array.from({ length: last - first + 1 }, (_, i) => last - i);
}

/** Totals of a year's twelve months (oldest first): opening, money in, money out, closing. */
export function yearTotals(
  months: readonly { masuk: string; keluar: string; saldo_akhir: string }[],
): { opening: number; totalIn: number; totalOut: number; closing: number } {
  const first = months[0];
  const last = months[months.length - 1];
  if (!first || !last) return { opening: 0, totalIn: 0, totalOut: 0, closing: 0 };
  const totalIn = months.reduce((sum, m) => sum + Number(m.masuk), 0);
  const totalOut = months.reduce((sum, m) => sum + Number(m.keluar), 0);
  return {
    opening: Number(first.saldo_akhir) - Number(first.masuk) + Number(first.keluar),
    totalIn,
    totalOut,
    closing: Number(last.saldo_akhir),
  };
}
