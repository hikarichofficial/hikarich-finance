"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname, useSearchParams } from "next/navigation";

/** How long the bar may stay up when a click turns out not to change the page (a download, a blocked leave). */
const GIVE_UP_AFTER_MS = 12000;

/** Decision 339: a Back/Forward step that is still showing the loading skeleton after this long is stuck (a
 * lost request, a cold start); the page is reloaded once instead of leaving the person staring at it. */
const STUCK_BACK_AFTER_MS = 15000;
const RELOAD_GUARD_KEY = "hikarich-stuck-reload-at";

/**
 * Click and loading feedback for every in-app link (decision 274, OWNER request): pages are rendered on the
 * server, so between pressing a menu and the new page arriving nothing on screen used to change. This shows a
 * progress bar at the top and marks the pressed link until the address actually changes.
 *
 * It listens once at the document instead of wrapping each `<Link>`, so plain `<a href>` links (the Entity
 * switcher) and links added later get the same feedback. "Pending" is remembered as the address the click
 * started from: as soon as the current address differs, the bar is gone without any effect having to reset it.
 */
export function NavigationProgress() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const here = `${pathname}?${searchParams.toString()}`;
  const [pendingFrom, setPendingFrom] = useState<string | null>(null);
  const hereRef = useRef(here);
  const pressed = useRef<HTMLAnchorElement | null>(null);
  const timer = useRef<number | null>(null);

  useEffect(() => {
    hereRef.current = here;
    // The page changed: the pressed link is no longer waiting.
    pressed.current?.removeAttribute("data-nav-pending");
    pressed.current = null;
    if (timer.current !== null) window.clearTimeout(timer.current);
    timer.current = null;
  }, [here]);

  useEffect(() => {
    function onClick(event: MouseEvent) {
      if (event.defaultPrevented || event.button !== 0) return;
      if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      const anchor = (event.target as Element | null)?.closest?.(
        "a[href]",
      ) as HTMLAnchorElement | null;
      if (!anchor || anchor.target === "_blank" || anchor.hasAttribute("download")) return;
      // A Quick Preview link only opens the side panel from data already on the page: nothing loads, so no bar
      // and no spinner (OWNER, 7 October 2026). A modified click is already skipped above and opens the page.
      if (anchor.hasAttribute("data-quick-preview")) return;
      let url: URL;
      try {
        url = new URL(anchor.href, window.location.href);
      } catch {
        return;
      }
      if (url.origin !== window.location.origin) return;
      const current = new URL(window.location.href);
      // Same page (or only a #hash jump): nothing will load.
      if (url.pathname === current.pathname && url.search === current.search) return;

      pressed.current?.removeAttribute("data-nav-pending");
      anchor.setAttribute("data-nav-pending", "true");
      pressed.current = anchor;
      setPendingFrom(hereRef.current);
      if (timer.current !== null) window.clearTimeout(timer.current);
      const startedAt = hereRef.current;
      const target = anchor.href;
      const isDownload = anchor.hasAttribute("download");
      timer.current = window.setTimeout(() => {
        pressed.current?.removeAttribute("data-nav-pending");
        pressed.current = null;
        setPendingFrom(null);
        // Still on the page the click started from: the in-app navigation never arrived, so open the
        // address as a normal page load rather than leaving the click without an answer (decision 339).
        if (!isDownload && hereRef.current === startedAt) window.location.assign(target);
      }, GIVE_UP_AFTER_MS);
    }
    // Capture phase: `<Link>` calls preventDefault in its own click handler, which would hide the click from
    // a listener that runs after it.
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
  }, []);

  // Browser Back/Forward: if the loading skeleton is still the only content after a long wait, reload once.
  useEffect(() => {
    let stuckTimer: number | null = null;
    function onPopState() {
      if (stuckTimer !== null) window.clearTimeout(stuckTimer);
      stuckTimer = window.setTimeout(() => {
        if (!document.querySelector('.app-content [aria-label="Memuat"]')) return;
        try {
          const last = Number(window.sessionStorage.getItem(RELOAD_GUARD_KEY) ?? "0");
          if (Date.now() - last < 60000) return;
          window.sessionStorage.setItem(RELOAD_GUARD_KEY, String(Date.now()));
        } catch {
          // Storage unavailable: reload anyway -- one extra load is harmless.
        }
        window.location.reload();
      }, STUCK_BACK_AFTER_MS);
    }
    window.addEventListener("popstate", onPopState);
    return () => {
      window.removeEventListener("popstate", onPopState);
      if (stuckTimer !== null) window.clearTimeout(stuckTimer);
    };
  }, []);

  const pending = pendingFrom !== null && pendingFrom === here;
  return (
    <div
      className="nav-progress no-print"
      data-active={pending ? "true" : undefined}
      role="status"
      aria-live="polite"
    >
      <span className="nav-progress-bar" />
      <span className="sr-only">{pending ? "Memuat halaman…" : ""}</span>
    </div>
  );
}
