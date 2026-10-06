import { exactTypeahead, matchTypeahead, normalizeTypeahead } from "@/domain/shared/typeahead";

/**
 * Suggestions for the description of an invoice, bill or expense line (OWNER, 5 October 2026): while a person
 * types a description, names already used on earlier lines (and the products on file) appear above the field,
 * with the price last used, so the same item is written the same way and its price is filled in for her. The
 * person may keep typing something different; a suggestion is only ever a convenience. Since 6 October 2026
 * the popup waits for the first typed character (see `@/domain/shared/typeahead`).
 */

export interface LineSuggestion {
  description: string;
  /** Plain decimal text, as stored ("150000", "12.5"). */
  unit_price: string;
  category_id: string | null;
}

export function normalizeDescription(text: string): string {
  return normalizeTypeahead(text);
}

/** Keeps the first (most recent) entry of every description, comparing case- and spacing-insensitively. */
export function dedupeSuggestions(rows: readonly LineSuggestion[]): LineSuggestion[] {
  const seen = new Set<string>();
  const result: LineSuggestion[] = [];
  for (const row of rows) {
    const key = normalizeDescription(row.description);
    if (key === "" || seen.has(key)) continue;
    seen.add(key);
    result.push(row);
  }
  return result;
}

/** What to offer for what has been typed so far. Nothing typed yet: nothing (clicking into the field must not open
 * the list). One character: names that start with it. Two or more: names that start with it first, then names that
 * contain it, each group keeping the recency order of the list. */
export function matchSuggestions(
  typed: string,
  all: readonly LineSuggestion[],
  limit = 6,
): LineSuggestion[] {
  return matchTypeahead(typed, all, (item) => item.description, limit);
}

/** The suggestion whose description is exactly what was typed, if any. */
export function exactSuggestion(
  typed: string,
  all: readonly LineSuggestion[],
): LineSuggestion | undefined {
  return exactTypeahead(typed, all, (item) => item.description);
}
