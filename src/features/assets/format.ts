/** Display-only date formatting for the Assets screens (Indonesian locale), matching
 * `@/features/tax/format`'s `formatShortDate` exactly (same short-date style used across every List/Detail
 * screen so far). Duplicated per that file's own precedent rather than shared, to keep each feature folder
 * self-contained. */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDate: string): string {
  return SHORT_DATE_FORMAT.format(new Date(`${isoDate}T00:00:00Z`));
}

const MONTH_FORMAT = new Intl.DateTimeFormat("id-ID", {
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

/** A depreciation schedule line's `month` is `YYYY-MM` (no day), unlike every other date in this codebase. */
export function formatMonth(yearMonth: string): string {
  return MONTH_FORMAT.format(new Date(`${yearMonth}-01T00:00:00Z`));
}
