import {
  RULE_FAMILY_LABELS,
  RULE_STATUS_LABELS,
  type RuleFamily,
  type RuleStatus,
} from "@/domain/tax/tax";
import type { TaxRuleVersionRow } from "@/schemas/tax";

/**
 * Pure helpers for the Tax Rules / Configuration List/Detail screen (decision 239, Step 05 §13). Nothing here
 * calls the database: `listTaxRuleVersions` (`src/services/tax/tax.ts`) already carries everything these
 * functions need. Filtering follows `@/domain/tax/taxLedgerList`'s own precedent exactly -- one list fetched
 * once, every filter applied client-side over it, since the rule master has at most a few hundred rows total
 * (every statutory value the system has ever asserted, across every family, Step 05 §13).
 *
 * This module deliberately shows the rule master as recorded, not a computed "which version is in force
 * right now" -- that computation already exists in the database (`app_private.tax_rule_at`,
 * `tax_rule_in_force`) and stays there rather than being reapproximated here: decision 237 found that
 * "today" itself is ambiguous between an Entity's timezone and the caller's, and re-deriving that comparison
 * in this layer risks the same class of bug for a screen whose whole purpose is to be trustworthy reference
 * data.
 */

const KNOWN_RULE_FAMILIES = new Set(Object.keys(RULE_FAMILY_LABELS));

function isKnownRuleFamily(value: string): value is RuleFamily {
  return KNOWN_RULE_FAMILIES.has(value);
}

/** The rule master's `family` column is plain text in the database, wider than what today's engine reads
 * (Step 05 §13) -- an unrecognised family still shows (as itself) rather than throwing, the same choice
 * `taxLedgerStatus` made for an unrecognised determination status. */
export function ruleFamilyLabel(family: string): string {
  return isKnownRuleFamily(family) ? RULE_FAMILY_LABELS[family] : family;
}

export interface RuleFamilyFilterOption {
  value: RuleFamily | null;
  label: string;
}

export const RULE_FAMILY_FILTER_OPTIONS: readonly RuleFamilyFilterOption[] = [
  { value: null, label: "Semua Kelompok" },
  ...(Object.entries(RULE_FAMILY_LABELS) as [RuleFamily, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function matchesRuleFamily(row: TaxRuleVersionRow, family: RuleFamily | null): boolean {
  return family === null || row.family === family;
}

export function parseRuleFamilyFilter(value: string | undefined): RuleFamily | undefined {
  const option = RULE_FAMILY_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

export interface RuleStatusFilterOption {
  value: RuleStatus | null;
  label: string;
}

export const RULE_STATUS_FILTER_OPTIONS: readonly RuleStatusFilterOption[] = [
  { value: null, label: "Semua Status" },
  ...(Object.entries(RULE_STATUS_LABELS) as [RuleStatus, string][]).map(([value, label]) => ({
    value,
    label,
  })),
];

export function matchesRuleStatus(row: TaxRuleVersionRow, status: RuleStatus | null): boolean {
  return status === null || row.status === status;
}

export function parseRuleStatusFilter(value: string | undefined): RuleStatus | undefined {
  const option = RULE_STATUS_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** Matches the rule code or its source title/reference -- the two things a person searching for "the PPN
 * rate rule" or "the one citing PMK 71" would type. */
export function matchesTaxRuleQuery(row: TaxRuleVersionRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.code).includes(needle) ||
    normalize(row.source_title).includes(needle) ||
    normalize(row.source_ref).includes(needle)
  );
}

export function filterTaxRuleRows(
  rows: readonly TaxRuleVersionRow[],
  family: RuleFamily | null,
  status: RuleStatus | null,
  query: string,
): TaxRuleVersionRow[] {
  return rows.filter(
    (row) =>
      matchesRuleFamily(row, family) &&
      matchesRuleStatus(row, status) &&
      matchesTaxRuleQuery(row, query),
  );
}
