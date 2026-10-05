"use client";

import { useId, useState } from "react";
import { needsReveal, REVEAL_CHARACTER_LIMIT } from "@/domain/products/descriptionReveal";

/**
 * Text cut to two lines that opens smoothly on "Selengkapnya" and closes again on "Ringkas". A text short
 * enough to fit is shown as is, with no button. The full text is always in the page (only visually cut),
 * so search in the browser and screen readers still find it.
 */
export function ExpandableText({
  text,
  limit = REVEAL_CHARACTER_LIMIT,
  className,
}: {
  text: string;
  limit?: number;
  className?: string;
}) {
  const [open, setOpen] = useState(false);
  const id = useId();
  const long = needsReveal(text, limit);
  const classes = [
    "expandable-text",
    long ? (open ? "expandable-text-open" : "expandable-text-cut") : "",
    className ?? "",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <div className={classes}>
      <p id={id} className="expandable-text-body">
        {text}
      </p>
      {long ? (
        <button
          type="button"
          className="expandable-text-toggle"
          aria-expanded={open}
          aria-controls={id}
          onClick={() => setOpen((value) => !value)}
        >
          {open ? "Ringkas" : "Selengkapnya"}
        </button>
      ) : null}
    </div>
  );
}
