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

/** WITA is UTC+8 and the business zone has no daylight saving, so a fixed offset is exact. */
export const BUSINESS_UTC_OFFSET_HOURS = 8;

/**
 * A reference instant moved onto the business time zone's wall clock, so the UTC getters (`getUTCFullYear`,
 * `getUTCMonth`, `toISOString().slice(0, 10)`) read the business calendar date instead of the UTC one. Use it
 * where a default report date is chosen from "now" (decision 303, finding #102).
 */
export function businessClock(reference: Date = new Date()): Date {
  return new Date(reference.getTime() + BUSINESS_UTC_OFFSET_HOURS * 60 * 60 * 1000);
}

/** Today's date (`YYYY-MM-DD`) in the business time zone. */
export function todayInBusinessZone(now: Date = new Date()): string {
  return dateInTimeZone(now);
}
