/**
 * Suggestions for the description of an invoice, bill or expense line (OWNER, 5 October 2026): while a person
 * types a description, names already used on earlier lines (and the products on file) appear above the field,
 * with the price last used, so the same item is written the same way and its price is filled in for her. The
 * person may keep typing something different; a suggestion is only ever a convenience.
 */

export interface LineSuggestion {
  description: string;
  /** Plain decimal text, as stored ("150000", "12.5"). */
  unit_price: string;
  category_id: string | null;
}

export function normalizeDescription(text: string): string {
  return text.trim().replace(/\s+/g, " ").toLowerCase();
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

/** What to offer for what has been typed so far. Nothing typed yet: the first few names on file, so the person
 * can simply click what already exists. One character: names that start with it. Two or more: names that start
 * with it first, then names that contain it, each group keeping the recency order of the list. */
export function matchSuggestions(
  typed: string,
  all: readonly LineSuggestion[],
  limit = 6,
): LineSuggestion[] {
  const query = normalizeDescription(typed);
  if (query === "") return all.slice(0, limit);
  const starts: LineSuggestion[] = [];
  const contains: LineSuggestion[] = [];
  for (const item of all) {
    const name = normalizeDescription(item.description);
    if (name.startsWith(query)) starts.push(item);
    else if (query.length >= 2 && name.includes(query)) contains.push(item);
  }
  return [...starts, ...contains].slice(0, limit);
}

/** The suggestion whose description is exactly what was typed, if any. */
export function exactSuggestion(
  typed: string,
  all: readonly LineSuggestion[],
): LineSuggestion | undefined {
  const query = normalizeDescription(typed);
  if (query === "") return undefined;
  return all.find((item) => normalizeDescription(item.description) === query);
}
