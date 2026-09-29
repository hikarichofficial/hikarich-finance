"use client";

import { useState, type MouseEvent, type ReactNode } from "react";
import Link from "next/link";
import { Drawer } from "./Drawer";

export interface RecordPreviewBadge {
  readonly tone: string;
  readonly text: string;
}

export interface RecordPreviewField {
  readonly label: string;
  readonly value: ReactNode;
}

/**
 * Quick Preview trigger for a List screen row (P13 Part 6, Step 09 §9: "Quick Preview: opens in side
 * drawer for fast review without losing list position"). Deliberately zero-network: every prop here is
 * data the row already has on the page (the same fields/badges/title that List screen's own `<table>`
 * already renders), so retrofitting a Register/List screen to use this is a presentational change only --
 * no new RPC, service wrapper or schema, and no risk of the preview disagreeing with the row it came from.
 * The full Detail page (Step 09 §10's complete Summary/Activity/Accounting/Tax/Documents/Audit
 * architecture) is unchanged and reachable from `fullLabel` inside the Drawer, or directly: this stays a
 * real `<a href>` under the hood, so a modified click (⌘/Ctrl/Shift/Alt) or middle-click still opens the
 * full record in a new tab exactly like a plain `<Link>` would, instead of the Drawer.
 */
export function RecordPreviewLink({
  href,
  label,
  eyebrow,
  title,
  badges = [],
  fields = [],
  fullLabel = "Lihat Detail Lengkap",
}: {
  href: string;
  label: ReactNode;
  eyebrow?: string;
  title: string;
  badges?: readonly RecordPreviewBadge[];
  fields?: readonly RecordPreviewField[];
  fullLabel?: string;
}) {
  const [open, setOpen] = useState(false);

  function onClick(event: MouseEvent<HTMLAnchorElement>) {
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    setOpen(true);
  }

  return (
    <>
      <a href={href} onClick={onClick}>
        {label}
      </a>
      <Drawer open={open} onClose={() => setOpen(false)} title={title}>
        {eyebrow ? <p className="record-detail-eyebrow">{eyebrow}</p> : null}
        {badges.length > 0 ? (
          <div className="drawer-badges">
            {badges.map((badge, index) => (
              <span key={index} className={`status-badge status-badge-${badge.tone}`}>
                {badge.text}
              </span>
            ))}
          </div>
        ) : null}
        {fields.length > 0 ? (
          <dl className="record-summary-grid">
            {fields.map((field, index) => (
              <div key={index}>
                <dt>{field.label}</dt>
                <dd>{field.value}</dd>
              </div>
            ))}
          </dl>
        ) : null}
        <Link href={href} className="btn-primary drawer-full-link">
          {fullLabel}
        </Link>
      </Drawer>
    </>
  );
}
