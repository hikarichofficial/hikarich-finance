"use client";

import { useEffect, useMemo, useState, type ReactNode } from "react";
import { useSearchParams } from "next/navigation";
import type { AccessSnapshot } from "@/schemas/access";
import { resolveActiveEntity } from "@/domain/authz/access";
import { visibleNavigation } from "@/domain/shell/navigation";
import { Sidebar } from "./Sidebar";
import { TopBar } from "./TopBar";
import { CommandMenu } from "./CommandMenu";

const COLLAPSE_STORAGE_KEY = "hikarich.sidebar.collapsed";

/**
 * The authenticated application chrome (Step 09 §2: Global Application Shell). `(app)/layout.tsx` calls
 * `requireAccess()` server-side (auth/MFA/active-user gating, per Step 06) and hands the resulting
 * snapshot down here as data; everything below is display and interaction only -- the database remains
 * the sole authority on what any of it means (DECISIONS #27).
 *
 * Next.js layouts do not receive `searchParams` (only pages do), so the *active* Entity for chrome
 * purposes is re-resolved client-side from the same `?entity=` param each page already reads for its own
 * `requireAccess({ entityCode })` call -- both read the identical query string, so they always agree.
 */
export function AppShell({ access, children }: { access: AccessSnapshot; children: ReactNode }) {
  const searchParams = useSearchParams();
  const switchable = useMemo(
    () => access.memberships.filter((m) => !m.mfa_required || m.mfa_satisfied),
    [access],
  );
  const membership = useMemo(
    () => resolveActiveEntity(access, searchParams.get("entity")) ?? switchable[0] ?? null,
    [access, searchParams, switchable],
  );
  const navigation = useMemo(() => visibleNavigation(membership?.permissions ?? []), [membership]);

  const [collapsed, setCollapsed] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [commandOpen, setCommandOpen] = useState(false);
  // Bumped every time the Command Menu opens; used as its `key` so it remounts with a clean search
  // field each time instead of needing to reset its own state on close.
  const [commandGeneration, setCommandGeneration] = useState(0);

  function openCommandMenu() {
    setCommandGeneration((value) => value + 1);
    setCommandOpen(true);
  }

  useEffect(() => {
    // Read-after-mount is deliberate, not an oversight: the server always renders "expanded" (it has no
    // access to the browser's localStorage), so restoring the saved preference before hydration would
    // make the client's first render disagree with the server's HTML. Doing it here, one paint after
    // hydration, is the standard fix for that mismatch.
    try {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setCollapsed(window.localStorage.getItem(COLLAPSE_STORAGE_KEY) === "1");
    } catch {
      // Private browsing / storage disabled: the sidebar just stays expanded, nothing breaks.
    }
  }, []);

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      const target = event.target as HTMLElement | null;
      const isTyping = target !== null && ["INPUT", "TEXTAREA"].includes(target.tagName);
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && !isTyping) {
        event.preventDefault();
        setCommandOpen((value) => {
          if (value) return false;
          setCommandGeneration((generation) => generation + 1);
          return true;
        });
      }
    }
    document.addEventListener("keydown", onKeyDown);
    return () => document.removeEventListener("keydown", onKeyDown);
  }, []);

  function toggleCollapse() {
    setCollapsed((prev) => {
      const next = !prev;
      try {
        window.localStorage.setItem(COLLAPSE_STORAGE_KEY, next ? "1" : "0");
      } catch {
        // Nothing to persist to; the in-memory state still toggles for this page view.
      }
      return next;
    });
  }

  if (!membership) {
    return (
      <div className="app-shell">
        <div className="app-content">
          <p>Tidak ada akses Entity yang tersedia.</p>
        </div>
      </div>
    );
  }

  const sidebarState = mobileOpen ? "open" : collapsed ? "collapsed" : undefined;

  return (
    <div className="app-shell" data-sidebar={sidebarState}>
      <Sidebar
        groups={navigation}
        collapsed={collapsed}
        onToggleCollapse={toggleCollapse}
        onNavigate={() => setMobileOpen(false)}
      />
      <div className="app-main">
        <TopBar
          displayName={access.display_name}
          membership={membership}
          switchable={switchable}
          onOpenMobileMenu={() => setMobileOpen(true)}
          onOpenCommandMenu={openCommandMenu}
        />
        <div className="app-content">{children}</div>
      </div>
      <button
        type="button"
        className="app-shell-scrim no-print"
        aria-label="Tutup menu"
        tabIndex={mobileOpen ? 0 : -1}
        onClick={() => setMobileOpen(false)}
      />
      <CommandMenu
        key={commandGeneration}
        open={commandOpen}
        onClose={() => setCommandOpen(false)}
        groups={navigation}
      />
    </div>
  );
}
