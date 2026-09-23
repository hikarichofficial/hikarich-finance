/** Display-only date formatting for the Sales screens (Indonesian locale), matching the short-date style
 * `@/features/dashboard/format`'s `formatShortDate` already uses and the long-date style
 * `formatDocumentDate` in `./InvoiceDocumentView` already uses for the customer-facing document. */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDate: string): string {
  return SHORT_DATE_FORMAT.format(new Date(`${isoDate}T00:00:00Z`));
}
