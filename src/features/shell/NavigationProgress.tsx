"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname, useSearchParams } from "next/navigation";

/** How long the bar may stay up when a click turns out not to change the page (a download, a blocked leave). */
const GIVE_UP_AFTER_MS = 12000;

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
      timer.current = window.setTimeout(() => {
        pressed.current?.removeAttribute("data-nav-pending");
        pressed.current = null;
        setPendingFrom(null);
      }, GIVE_UP_AFTER_MS);
    }
    // Capture phase: `<Link>` calls preventDefault in its own click handler, which would hide the click from
    // a listener that runs after it.
    document.addEventListener("click", onClick, true);
    return () => document.removeEventListener("click", onClick, true);
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
