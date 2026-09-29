"use client";

import { useEffect, useRef, type ReactNode } from "react";
import { X } from "lucide-react";

/**
 * Generic right-side Drawer primitive (P13 Part 6, Step 09 §2/§27, Step 10 §8/§19/§26). The Context
 * Panel / Drawer region of the Global Application Shell (Step 09 §2: "Quick view, filters, create/edit
 * forms, activity or supporting detail without unnecessary page changes"), and one of the named reusable
 * patterns Step 09 §28's Implementation Contract requires ("Drawer... patterns"). This component holds no
 * record-specific knowledge -- `RecordPreviewLink` is the List-screen-facing pattern built on top of it
 * for Quick Preview (Step 09 §9); other Drawer uses (filters, lightweight create/edit) can reuse this same
 * primitive later without changing it.
 *
 * Entrance uses a one-shot `animation` (Step 10 §8: "smooth scale/slide with natural easing"), not a
 * `transition`, because the panel mounts and unmounts with `open` rather than staying in the DOM --
 * animations run on their own once mounted, so this needs no extra JS to trigger it. `--motion-base`
 * already collapses to `0ms` under `prefers-reduced-motion: reduce` (decision 156); the explicit
 * `animation: none` override below matches the same belt-and-suspenders style decision 213's skeleton
 * pulse already established, rather than relying on the token alone.
 */
export function Drawer({
  open,
  onClose,
  title,
  children,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  children: ReactNode;
}) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose();
    }
    document.addEventListener("keydown", onKeyDown);
    // Move focus into the panel on open so Escape/Tab work immediately, and so focus does not stay
    // behind the overlay on the row link that opened it.
    panelRef.current?.focus();
    return () => document.removeEventListener("keydown", onKeyDown);
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="drawer-overlay no-print" onClick={onClose}>
      <div
        ref={panelRef}
        className="drawer-panel"
        role="dialog"
        aria-modal="true"
        aria-label={title}
        tabIndex={-1}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="drawer-header">
          <h2>{title}</h2>
          <button type="button" className="icon-button" onClick={onClose} aria-label="Tutup">
            <X size={18} strokeWidth={1.75} aria-hidden="true" />
          </button>
        </div>
        <div className="drawer-body">{children}</div>
      </div>
    </div>
  );
}
