import type { CalendarState } from "@/domain/tax/tax";

/**
 * Pure helpers for the Tax Calendar screen (P13 unbuilt-screens backlog, "Tax Calendar" nav item, Step 09 §15,
 * decision 233). Nothing here calls the database: `getTaxCalendar` (`src/services/tax/tax.ts`) already carries
 * everything this screen needs -- `tax_calendar` itself is gated on `tax.view`, the same permission the Tax nav
 * section's own parent item already requires, so this page's own gate is written directly against it rather
 * than the section (the same discipline decisions 229/232 already applied).
 */

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export interface TaxCalendarRange {
  from: string;
  to: string;
}

/**
 * Default window when no valid explicit `from`/`to` is given: one month back through two months ahead of today,
 * so a recently missed deadline and an upcoming one are both visible without a query. `tax_calendar` itself
 * defaults to the past three months only when its own arguments are omitted (Step 05's read side is written for
 * a ledger-style "what happened" query) -- this page widens and re-centres that window on today's date instead,
 * since Step 09 §15 calls this screen a "calendar" rather than a ledger. `tax_calendar` truncates whatever date
 * it receives to the start of that month itself (`date_trunc('month', ...)`), so this helper does not need to.
 * Whatever the user actually asks for (both dates valid, `from` on or before `to`) is used exactly as given --
 * `tax_calendar`'s own 36-month span limit is left to the database to enforce, matching the "no stricter than
 * the RPC" precedent (decision 232's own `eligibleCounterAccounts`).
 */
export function resolveTaxCalendarRange(
  requestedFrom: string | undefined,
  requestedTo: string | undefined,
  reference: Date = new Date(),
): TaxCalendarRange {
  const validFrom =
    requestedFrom && ISO_DATE_PATTERN.test(requestedFrom) ? requestedFrom : undefined;
  const validTo = requestedTo && ISO_DATE_PATTERN.test(requestedTo) ? requestedTo : undefined;
  if (validFrom && validTo && validFrom <= validTo) {
    return { from: validFrom, to: validTo };
  }
  const from = new Date(Date.UTC(reference.getUTCFullYear(), reference.getUTCMonth() - 1, 1));
  const to = new Date(Date.UTC(reference.getUTCFullYear(), reference.getUTCMonth() + 2, 1));
  return { from: toIsoDate(from), to: toIsoDate(to) };
}

/** The status badge tone each calendar state shows, matching `TaxOverviewScreen`'s own "Tenggat Terdekat"
 * section (which shows the same `tax_calendar` rows, curated to a two-month attention list by `tax_overview`)
 * -- duplicated here per `@/features/tax/format`'s own precedent of keeping each screen's small display helpers
 * self-contained rather than sharing them across feature files. */
export const CALENDAR_STATE_BADGE_TONE: Readonly<Record<CalendarState, string>> = {
  overdue: "status-badge-critical",
  due: "status-badge-attention",
  upcoming: "status-badge-progress",
  done: "status-badge-success",
  not_applicable: "status-badge-neutral",
  no_rule: "status-badge-neutral",
};
