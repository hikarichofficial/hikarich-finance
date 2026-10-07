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
