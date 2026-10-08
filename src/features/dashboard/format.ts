/** Display-only date formatting for the Dashboard (Indonesian locale, matching
 * `formatDocumentDate` in `@/features/sales/InvoiceDocumentView`). */

const SHORT_DATE_FORMAT = new Intl.DateTimeFormat("id-ID", {
  day: "numeric",
  month: "short",
  timeZone: "UTC",
});

const MONTH_LABEL_FORMAT = new Intl.DateTimeFormat("id-ID", {
  month: "long",
  year: "numeric",
  timeZone: "UTC",
});

export function formatShortDate(isoDate: string): string {
  return SHORT_DATE_FORMAT.format(new Date(`${isoDate}T00:00:00Z`));
}

/** "2026-09" -> "September 2026". */
export function formatMonthLabel(month: string): string {
  return MONTH_LABEL_FORMAT.format(new Date(`${month}-01T00:00:00Z`));
}

export function previousMonth(month: string): string {
  const [year, m] = month.split("-").map(Number);
  const d = new Date(Date.UTC(year, m - 2, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

export function nextMonth(month: string): string {
  const [year, m] = month.split("-").map(Number);
  const d = new Date(Date.UTC(year, m, 1));
  return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, "0")}`;
}

const MONTH_SHORT_FORMAT = new Intl.DateTimeFormat("id-ID", { month: "short", timeZone: "UTC" });

/** "2026-09" -> "Sep" (a chart axis label). */
export function formatMonthShort(month: string): string {
  return MONTH_SHORT_FORMAT.format(new Date(`${month}-01T00:00:00Z`));
}

/** "2026-02" -> first and last day of that month. */
export function monthRange(month: string): { start: string; end: string } {
  const [year, m] = month.split("-").map(Number);
  const last = new Date(Date.UTC(year, m, 0)).getUTCDate();
  return { start: `${month}-01`, end: `${month}-${String(last).padStart(2, "0")}` };
}

/** The report a chart point opens: the statement for that whole month. */
export function reportHref(statement: "pnl" | "cashflow", month: string, section?: string): string {
  const { start, end } = monthRange(month);
  const query = new URLSearchParams({ statement, from: start, to: end });
  return `/reports?${query.toString()}${section ? `#${section}` : ""}`;
}
