"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import type { NavGroup } from "@/domain/shell/navigation";
import type { QuickCreateItem } from "@/domain/shell/quickCreate";
import type { SearchResultRow } from "@/schemas/search";
import { SEARCH_TARGET_TYPE_LABELS } from "@/domain/search/search";
import { searchResultHref } from "@/domain/search/routes";
import { searchRecordsAction } from "./searchActions";

interface FlatEntry {
  readonly label: string;
  readonly href: string;
  readonly group: string;
}

const QUICK_CREATE_GROUP_LABEL = "Buat Baru";
const SEARCH_MIN_LENGTH = 2;
const SEARCH_DEBOUNCE_MS = 250;

function flatten(
  groups: readonly NavGroup[],
  quickCreate: readonly QuickCreateItem[],
): FlatEntry[] {
  const entries: FlatEntry[] = quickCreate.map((item) => ({
    label: item.label,
    href: item.href,
    group: QUICK_CREATE_GROUP_LABEL,
  }));
  for (const group of groups) {
    for (const item of group.items ?? [{ label: group.label, href: group.href }]) {
      entries.push({ label: item.label, href: item.href, group: group.label });
    }
  }
  return entries;
}

/**
 * Command Menu structural shell (Step 09 §7, Step 10 §18). Navigation-only in P13 Part 1: it searched
 * the same fixed sitemap the Sidebar renders. P13 Part 4's eleventh increment adds the first non-navigation
 * result source, the quick-create registry (`@/domain/shell/quickCreate`, DECISIONS 199) -- already
 * filtered to what this membership may reach by the caller (`AppShell`, the same "filter before it
 * reaches the component" shape `visibleNavigation`'s own `groups` prop already uses), so this component
 * never re-checks a permission itself. Quick-create entries are flattened into the same `FlatEntry` list
 * as navigation results (`"Buat Baru"` as their `group` label) rather than rendered as a separate,
 * always-visible section: they search and sort exactly like every other result, so typing "anggaran"
 * surfaces both the Budgets nav entry and the "Anggaran Baru" quick-create action together, and an
 * empty query shows quick-create first only because `flatten` lists it first -- consistent with a single
 * unified result list rather than two independently laid-out ones.
 *
 * Global Search (P13 Part 6, Step 09 §6, Step 13 §17: "Command Menu navigation/action search remains
 * separate from financial content search") is wired in as a second, separately-labelled section below the
 * navigation list rather than merged into `results` above: a nav/quick-create match is synchronous and
 * local, a search match is a debounced round trip to `public.search` (`searchRecordsAction`), and the
 * spec's own §13/§17 language treats them as two different kinds of find, not one ranked list. A query
 * under `SEARCH_MIN_LENGTH` characters never fires the search action at all, matching `search()`'s own
 * server-side minimum and avoiding a network call on every single keystroke. `latestQueryRef` guards
 * against an out-of-order response: if the person kept typing after a request went out, an older
 * response that resolves later is simply dropped instead of flashing stale results.
 */
export function CommandMenu({
  open,
  onClose,
  groups,
  quickCreate,
  entityId,
}: {
  open: boolean;
  onClose: () => void;
  groups: readonly NavGroup[];
  quickCreate: readonly QuickCreateItem[];
  entityId: string;
}) {
  const router = useRouter();
  // AppShell remounts this component (via a changing `key`) every time it opens, so `query` always
  // starts empty on open without this component needing to reset itself in an effect.
  const [query, setQuery] = useState("");
  const [searchResults, setSearchResults] = useState<readonly SearchResultRow[]>([]);
  const [searching, setSearching] = useState(false);
  const latestQueryRef = useRef("");

  const entries = useMemo(() => flatten(groups, quickCreate), [groups, quickCreate]);
  const results = useMemo(() => {
    const q = query.trim().toLowerCase();
    const matches = q ? entries.filter((entry) => entry.label.toLowerCase().includes(q)) : entries;
    return matches.slice(0, 8);
  }, [entries, query]);

  useEffect(() => {
    if (!open) return;
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open, onClose]);

  // No setState runs synchronously in this effect body -- `showSearch` (below) already gates whether
  // `searchResults`/`searching` render at all for a too-short query, so the early return below needs no
  // state reset of its own. A stale result set briefly showing again if the person retypes the same query
  // right after shortening it is deliberate, not a bug: better a moment of the previous match than an
  // empty flash while the new debounced search is still in flight.
  useEffect(() => {
    const trimmed = query.trim();
    latestQueryRef.current = trimmed;
    if (trimmed.length < SEARCH_MIN_LENGTH) return;
    const timer = setTimeout(() => {
      setSearching(true);
      searchRecordsAction(entityId, trimmed)
        .then((rows) => {
          if (latestQueryRef.current !== trimmed) return;
          setSearchResults(rows);
        })
        .finally(() => {
          if (latestQueryRef.current === trimmed) setSearching(false);
        });
    }, SEARCH_DEBOUNCE_MS);
    return () => clearTimeout(timer);
  }, [query, entityId]);

  if (!open) return null;

  const showSearch = query.trim().length >= SEARCH_MIN_LENGTH;

  function go(href: string) {
    onClose();
    router.push(href);
  }

  return (
    // Standard modal-backdrop pattern: click-to-close is a mouse convenience layered on top of the
    // Escape-key handler wired above (this effect's own `onKeyDown`), which is the real keyboard
    // equivalent -- the backdrop itself carries no semantics and needs none of its own.
    // eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions
    <div className="command-menu-overlay no-print" onClick={onClose}>
      {/* onClick here only stops the backdrop's onClose from firing when a click lands inside the
          panel -- it is not itself a user-facing interaction, so it needs no keyboard equivalent.
          The panel's real semantics (role="dialog", aria-modal, aria-label) and its real interactive
          controls (the input and the result buttons below) are unaffected. */}
      {/* eslint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-noninteractive-element-interactions */}
      <div
        className="command-menu-panel"
        role="dialog"
        aria-modal="true"
        aria-label="Menu perintah"
        onClick={(event) => event.stopPropagation()}
      >
        <input
          // Command palettes (VS Code, Linear, Slack, etc.) conventionally auto-focus their search
          // input, and it is safe here specifically because the palette itself only ever opens from an
          // explicit user-initiated keyboard shortcut (never on page load or programmatically), so
          // autoFocus moves focus in direct response to the same keypress that opened it, not away
          // from something the user was already doing unprompted.
          // eslint-disable-next-line jsx-a11y/no-autofocus
          autoFocus
          type="text"
          className="command-menu-input"
          placeholder="Cari halaman atau data..."
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="command-menu-list" role="listbox">
          {results.length === 0 && (!showSearch || (!searching && searchResults.length === 0)) ? (
            <div className="command-menu-empty">Tidak ada hasil.</div>
          ) : (
            <>
              {results.map((entry) => (
                <button
                  key={entry.href}
                  type="button"
                  className="command-menu-item"
                  role="option"
                  aria-selected={false}
                  onClick={() => go(entry.href)}
                >
                  {entry.group} · {entry.label}
                </button>
              ))}
              {showSearch ? (
                <>
                  <div className="command-menu-section-label">
                    {searching ? "Mencari…" : "Hasil Pencarian"}
                  </div>
                  {searchResults.map((row) => {
                    const href = searchResultHref(row);
                    const groupLabel = SEARCH_TARGET_TYPE_LABELS[row.target_type];
                    const key = `${row.target_type}-${row.target_id}`;
                    if (!href) {
                      return (
                        <div key={key} className="command-menu-item command-menu-item-disabled">
                          {groupLabel} · {row.title}
                        </div>
                      );
                    }
                    return (
                      <button
                        key={key}
                        type="button"
                        className="command-menu-item"
                        role="option"
                        aria-selected={false}
                        onClick={() => go(href)}
                      >
                        {groupLabel} · {row.title}
                        {row.subtitle ? ` — ${row.subtitle}` : ""}
                      </button>
                    );
                  })}
                </>
              ) : null}
            </>
          )}
        </div>
      </div>
    </div>
  );
}
