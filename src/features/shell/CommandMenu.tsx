"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { NavGroup } from "@/domain/shell/navigation";
import type { QuickCreateItem } from "@/domain/shell/quickCreate";

interface FlatEntry {
  readonly label: string;
  readonly href: string;
  readonly group: string;
}

const QUICK_CREATE_GROUP_LABEL = "Buat Baru";

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
 * unified result list rather than two independently laid-out ones. Search-across-records (Global Search,
 * `public.search`) stays unwired -- still no settled data-fetching pattern for a debounced, server-backed
 * result source inside this synchronous local-filter shell.
 */
export function CommandMenu({
  open,
  onClose,
  groups,
  quickCreate,
}: {
  open: boolean;
  onClose: () => void;
  groups: readonly NavGroup[];
  quickCreate: readonly QuickCreateItem[];
}) {
  const router = useRouter();
  // AppShell remounts this component (via a changing `key`) every time it opens, so `query` always
  // starts empty on open without this component needing to reset itself in an effect.
  const [query, setQuery] = useState("");

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

  if (!open) return null;

  function go(href: string) {
    onClose();
    router.push(href);
  }

  return (
    <div className="command-menu-overlay no-print" onClick={onClose}>
      <div
        className="command-menu-panel"
        role="dialog"
        aria-modal="true"
        aria-label="Menu perintah"
        onClick={(event) => event.stopPropagation()}
      >
        <input
          autoFocus
          type="text"
          className="command-menu-input"
          placeholder="Cari halaman..."
          value={query}
          onChange={(event) => setQuery(event.target.value)}
        />
        <div className="command-menu-list" role="listbox">
          {results.length === 0 ? (
            <div className="command-menu-empty">Tidak ada hasil.</div>
          ) : (
            results.map((entry) => (
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
            ))
          )}
        </div>
      </div>
    </div>
  );
}
