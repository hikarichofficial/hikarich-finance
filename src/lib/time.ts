/**
 * Calendar-date helpers pinned to the business time zone (WITA by default, same as the database's Entity
 * default), so a default date never slips a day backwards between 00:00 and 08:00 WITA the way
 * UTC `toISOString()` slicing does. Pure and usable from server and client components alike.
 */
export const BUSINESS_TIME_ZONE = "Asia/Makassar";

/** `YYYY-MM-DD` of `at` as seen in `timeZone`. */
export function dateInTimeZone(at: Date, timeZone: string = BUSINESS_TIME_ZONE): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(at);
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/** Today's date (`YYYY-MM-DD`) in the business time zone. */
export function todayInBusinessZone(now: Date = new Date()): string {
  return dateInTimeZone(now);
}
