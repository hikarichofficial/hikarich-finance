/** Display-only timestamp formatting for the Audit Log (Indonesian locale). Audit events are compared to
 * the second, so unlike other screens' date-only `formatShortDate` this keeps the time -- shown in UTC and
 * labelled as such, since an audit trail spans Entities whose own timezones may differ (decision 237). */

const DATE_TIME_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  year: "numeric",
  hour: "2-digit",
  minute: "2-digit",
  second: "2-digit",
  hour12: false,
  timeZone: "UTC",
});

export function formatAuditTimestamp(isoDateTime: string): string {
  return `${DATE_TIME_FORMAT.format(new Date(isoDateTime))} UTC`;
}
