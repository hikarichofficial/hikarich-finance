/** Display-only date formatting for the Planning screens (Indonesian locale), matching
 * `@/features/assets/format`'s `formatShortDate` exactly (same short-date style used across every List/Detail
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

/** Month-only label ("Jan 2026") for the Budget/Revenue Target "set lines" grid's own month columns/rows
 * (P13 Part 3h, fifth increment) -- a day-of-month would be misleading there since `period_month` is always
 * the first of the month. */
const MONTH_LABEL_FORMAT = new Intl.DateTimeFormat("id-ID", {
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatMonthLabel(periodMonth: string): string {
  return MONTH_LABEL_FORMAT.format(new Date(`${periodMonth}T00:00:00Z`));
}
