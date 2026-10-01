/** Display-only date formatting for the Import history screens (Indonesian locale), duplicated per feature
 * folder like every other `format.ts` (decision 194's precedent). `created_at` is a full `timestamptz`, so
 * it is parsed directly. */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDateTime: string): string {
  return SHORT_DATE_FORMAT.format(new Date(isoDateTime));
}
