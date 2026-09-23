/** Display-only date formatting for the Money screens (Indonesian locale), matching
 * `@/features/sales/format`'s `formatShortDate` exactly (same short-date style used across every List/Detail
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
