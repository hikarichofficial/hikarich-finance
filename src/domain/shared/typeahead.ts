/**
 * The rules every "type and pick" field shares -- a customer or vendor, a category, a recipient's name, the
 * description of a line. Since 8 October 2026 (OWNER: "kategori tetap menampilkan semua kategori referensi, kalau
 * menunggu ketikan bisa saja lupa harus memilih yang mana") clicking into the field opens the list of everything that
 * can be picked, scrollable, with the add-new row kept in it; typing narrows the list from the first character
 * (this replaces the rule of 6 October 2026 that the list waited for the first typed character).
 * A suggestion is only ever a convenience -- the person may keep typing something else.
 */

/** How many entries the list shows before anything is typed: the whole reference list, up to a sane ceiling. */
export const BROWSE_LIMIT = 200;

/** What the list shows. Nothing typed (or the field just shows the chosen name): everything, most recent first as
 * given. Something typed: the matches of `matchTypeahead`. */
export function browseTypeahead<T>(
  typed: string | null,
  all: readonly T[],
  nameOf: (item: T) => string,
  searchLimit = 8,
  browseLimit = BROWSE_LIMIT,
): T[] {
  if (typed === null || !hasTyped(typed)) return all.slice(0, browseLimit);
  return matchTypeahead(typed, all, nameOf, searchLimit);
}

export function normalizeTypeahead(text: string): string {
  return text.trim().replace(/\s+/g, " ").toLowerCase();
}

/** Whether the person has typed anything yet (spaces alone do not count). The popup stays shut until they have. */
export function hasTyped(text: string): boolean {
  return normalizeTypeahead(text) !== "";
}

/**
 * What to offer for what has been typed. Nothing typed: nothing (use `browseTypeahead` to show everything). One character: names that start with it. Two or more: names that
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
