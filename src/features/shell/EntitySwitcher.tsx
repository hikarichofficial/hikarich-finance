"use client";

import { useEffect, useRef, useState } from "react";
import { usePathname } from "next/navigation";
import { ChevronDown } from "lucide-react";
import type { Membership } from "@/schemas/access";
import { entityLabel } from "@/domain/authz/access";

/**
 * Entity switcher (Step 09 §5): PT and Personal are always distinct ledgers (Step 01 #4), never merged,
 * so switching just changes the `?entity=` query param -- the same mechanism P2's Home page already used
 * (`requireAccess({ entityCode })` on the server), now surfaced shell-wide instead of per-page.
 */
export function EntitySwitcher({
  current,
  switchable,
}: {
  current: Membership;
  switchable: readonly Membership[];
}) {
  const [open, setOpen] = useState(false);
  const pathname = usePathname();
  const rootRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    function onPointerDown(event: PointerEvent) {
      if (rootRef.current && !rootRef.current.contains(event.target as Node)) setOpen(false);
    }
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") setOpen(false);
    }
    document.addEventListener("pointerdown", onPointerDown);
    document.addEventListener("keydown", onKeyDown);
    return () => {
      document.removeEventListener("pointerdown", onPointerDown);
      document.removeEventListener("keydown", onKeyDown);
    };
  }, [open]);

  const mark = entityLabel(current).slice(0, 2).toUpperCase();

  if (switchable.length <= 1) {
    return (
      <div className="entity-switcher-trigger">
        <span className="entity-switcher-mark" aria-hidden="true">
          {mark}
        </span>
        {entityLabel(current)}
      </div>
    );
  }

  return (
    <div className="entity-switcher" ref={rootRef}>
      <button
        type="button"
        className="entity-switcher-trigger"
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((value) => !value)}
      >
        <span className="entity-switcher-mark" aria-hidden="true">
          {mark}
        </span>
        {entityLabel(current)}
        <ChevronDown size={14} strokeWidth={2} aria-hidden="true" />
      </button>
      {open ? (
        <div className="entity-switcher-menu" role="menu">
          {switchable.map((membership) => (
            <a
              key={membership.entity_id}
              href={`${pathname}?entity=${encodeURIComponent(membership.entity_code)}`}
              className="entity-switcher-item"
              role="menuitem"
              aria-current={membership.entity_id === current.entity_id ? "true" : undefined}
              onClick={() => setOpen(false)}
            >
              <strong>{membership.entity_name}</strong>
              <span>
                {entityLabel(membership)} · {membership.role_key.toUpperCase()}
              </span>
            </a>
          ))}
        </div>
      ) : null}
    </div>
  );
}
