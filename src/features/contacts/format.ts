/** Display-only date formatting for the Contacts screens (Indonesian locale), matching every other
 * feature folder's own `formatShortDate` precedent -- duplicated rather than shared, to keep each feature
 * folder self-contained. A contact's `created_at`/`updated_at` are full timestamps (`timestamptz`), the
 * same shape `@/features/documents/format`'s own comment explains, so this parses directly with no
 * `T00:00:00Z` suffix. */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDateTime: string): string {
  return SHORT_DATE_FORMAT.format(new Date(isoDateTime));
}
