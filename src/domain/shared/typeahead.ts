/**
 * The rules every "type and pick" field shares -- a customer or vendor, a recipient's name, the description of a
 * line (OWNER, 6 October 2026): clicking into the field only puts the cursor there and shows nothing; the popup
 * appears once the person starts typing, straight away from the first character, and narrows as more is typed.
 * A suggestion is only ever a convenience -- the person may keep typing something else.
 */

export function normalizeTypeahead(text: string): string {
  return text.trim().replace(/\s+/g, " ").toLowerCase();
}

/** Whether the person has typed anything yet (spaces alone do not count). The popup stays shut until they have. */
export function hasTyped(text: string): boolean {
  return normalizeTypeahead(text) !== "";
}

/**
 * What to offer for what has been typed. Nothing typed: nothing (not "the first few names": the list must not
 * open just because the field was clicked). One character: names that start with it. Two or more: names that
 * start with it first, then names that contain it, each group keeping the order of `all` (most recent first).
 */
export function matchTypeahead<T>(
  typed: string,
  all: readonly T[],
  nameOf: (item: T) => string,
  limit = 6,
): T[] {
  const query = normalizeTypeahead(typed);
  if (query === "") return [];
  const starts: T[] = [];
  const contains: T[] = [];
  for (const item of all) {
    const name = normalizeTypeahead(nameOf(item));
    if (name.startsWith(query)) starts.push(item);
    else if (query.length >= 2 && name.includes(query)) contains.push(item);
  }
  return [...starts, ...contains].slice(0, limit);
}

/** The entry whose name is exactly what was typed (ignoring case and spacing), if any. */
export function exactTypeahead<T>(
  typed: string,
  all: readonly T[],
  nameOf: (item: T) => string,
): T | undefined {
  const query = normalizeTypeahead(typed);
  if (query === "") return undefined;
  return all.find((item) => normalizeTypeahead(nameOf(item)) === query);
}

/** Keeps the first (most recent) occurrence of each name, ignoring case and spacing, and drops blank ones. */
export function dedupeNames(names: readonly (string | null | undefined)[]): string[] {
  const seen = new Set<string>();
  const result: string[] = [];
  for (const name of names) {
    if (typeof name !== "string") continue;
    const key = normalizeTypeahead(name);
    if (key === "" || seen.has(key)) continue;
    seen.add(key);
    result.push(name.trim().replace(/\s+/g, " "));
  }
  return result;
}
