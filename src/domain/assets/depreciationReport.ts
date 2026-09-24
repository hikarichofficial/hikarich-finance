import { Decimal, sumDecimals } from "@/domain/money/decimal";
import type { DepreciationDueRow, DepreciationLineRow } from "@/schemas/assets";

/**
 * Pure helpers for the Depreciation report (P13 Part 3f, fifth and final increment, Step 09 §9, §16; Step 12's
 * report catalogue: "Accounting Depreciation Schedule by asset/period"). Nothing here calls the database:
 * `depreciationReport`/`depreciationDue` (`src/services/assets/assets.ts`) already carry everything these
 * functions need. The line-status badge is not duplicated here -- `depreciationLineRowSchema.status` shares its
 * exact vocabulary with `assetDetailSchema.schedule[].status`, so this screen reuses `depreciationLineStatusBadge`
 * from `@/domain/assets/assetList` directly instead of a second copy.
 */

export interface DepreciationRange {
  from: string;
  to: string;
}

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

/** Defaults to the trailing 12 months, unlike Cash/Bank Activity's trailing 30 days (`resolveActivityRange`,
 * P13 Part 3c) -- depreciation posts monthly, so a 30-day window would show at most one period for most
 * assets. Falls back to the trailing-12-months default whenever the request omits either bound or gives an
 * inverted range, mirroring `resolveActivityRange`'s own validation exactly. */
export function resolveDepreciationRange(
  requestedFrom: string | undefined,
  requestedTo: string | undefined,
  reference: Date = new Date(),
): DepreciationRange {
  const validFrom =
    requestedFrom && ISO_DATE_PATTERN.test(requestedFrom) ? requestedFrom : undefined;
  const validTo = requestedTo && ISO_DATE_PATTERN.test(requestedTo) ? requestedTo : undefined;
  if (validFrom && validTo && validFrom <= validTo) {
    return { from: validFrom, to: validTo };
  }
  const to = toIsoDate(reference);
  const from = toIsoDate(new Date(reference.getTime() - 364 * 24 * 60 * 60 * 1000));
  return { from, to };
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `period_month` and `status` are both already filtered server-side (the range going straight into
 * `asset_depreciation_report`'s own `p_from`/`p_to`); only the free-text asset code/name search has no RPC
 * parameter to send it to, like every other List screen's client-side query. */
export function matchesDepreciationQuery(row: DepreciationLineRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return normalize(row.asset_code).includes(needle) || normalize(row.asset_name).includes(needle);
}

export function filterDepreciationRows(
  rows: readonly DepreciationLineRow[],
  query: string,
): DepreciationLineRow[] {
  return rows.filter((row) => matchesDepreciationQuery(row, query));
}

export interface DepreciationTotals {
  posted: Decimal;
  scheduled: Decimal;
}

/** Posted vs. scheduled totals for the rows on screen (Step 09 §19's "filter bar + summary + table" pattern).
 * Reversed and cancelled lines carry no weight in either figure: a reversal already nets to zero in the
 * ledger, and this report is not itself the ledger. */
export function depreciationTotals(rows: readonly DepreciationLineRow[]): DepreciationTotals {
  const posted = sumDecimals(
    rows.filter((r) => r.status === "posted").map((r) => Decimal.parse(r.amount)),
  );
  const scheduled = sumDecimals(
    rows.filter((r) => r.status === "scheduled").map((r) => Decimal.parse(r.amount)),
  );
  return { posted, scheduled };
}

/** The attention band on the same screen (Step 12: months due but not posted) -- only the rows the accounting
 * period still accepts a posting for; a due-but-closed-period row is shown for visibility but not counted
 * here, since nothing on this screen can act on it anyway. */
export function depreciationDuePostable(
  rows: readonly DepreciationDueRow[],
): readonly DepreciationDueRow[] {
  return rows.filter((r) => r.postable);
}
