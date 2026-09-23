"use client";

import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import type { NavGroup } from "@/domain/shell/navigation";

interface FlatEntry {
  readonly label: string;
  readonly href: string;
  readonly group: string;
}

function flatten(groups: readonly NavGroup[]): FlatEntry[] {
  const entries: FlatEntry[] = [];
  for (const group of groups) {
    for (const item of group.items ?? [{ label: group.label, href: group.href }]) {
      entries.push({ label: item.label, href: item.href, group: group.label });
    }
  }
  return entries;
}

/**
 * Command Menu structural shell (Step 09 §7, Step 10 §18). Navigation-only in P13 Part 1: it searches
 * the same fixed sitemap the Sidebar renders. Search-across-records and quick-create are wired in P13
 * Part 4 once the data-fetching pattern for them is settled -- this component's job here is only the
 * open/close/keyboard/focus mechanics and the visual shell, so Part 4 only adds result sources.
 */
export function CommandMenu({
  open,
  onClose,
  groups,
}: {
  open: boolean;
  onClose: () => void;
  groups: readonly NavGroup[];
}) {
  const router = useRouter();
  // AppShell remounts this component (via a changing `key`) every time it opens, so `query` always
  // starts empty on open without this component needing to reset itself in an effect.
  const [query, setQuery] = useState("");

  const entries = useMemo(() => flatten(groups), [groups]);
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
