import { BUSINESS_TIME_ZONE } from "@/lib/time";

/** Display-only timestamp formatting for the Audit Log (Indonesian locale). Audit events are compared to
 * the second, so unlike other screens' date-only `formatShortDate` this keeps the time. It is shown in the
 * business time zone (WITA) and labelled as such (decision 303, finding #103: the OWNER reads the trail in
 * local time; decision 237 had shown UTC). The stored instant is unchanged. */

const DATE_TIME_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
  timeZone: BUSINESS_TIME_ZONE,
});

export function formatAuditTimestamp(isoDateTime: string): string {
  return `${DATE_TIME_FORMAT.format(new Date(isoDateTime))} WITA`;
}
