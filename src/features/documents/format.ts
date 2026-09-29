/** Display-only date formatting for the Documents screens (Indonesian locale), matching every other
 * feature folder's own `formatShortDate` precedent -- duplicated rather than shared, to keep each feature
 * folder self-contained. Unlike a bill/invoice date (a plain `YYYY-MM-DD`), a document's `created_at` is a
 * full timestamp (`timestamptz`), so this parses it directly rather than appending a `T00:00:00Z` suffix. */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDateTime: string): string {
  return SHORT_DATE_FORMAT.format(new Date(isoDateTime));
}
