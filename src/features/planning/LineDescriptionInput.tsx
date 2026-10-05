"use client";

import { useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { formatPlain } from "@/domain/money/format";
import { matchSuggestions, type LineSuggestion } from "@/domain/sales/lineSuggestions";

interface PopupPosition {
  left: number;
  width: number;
  top?: number;
  bottom?: number;
}

/**
 * The description of a line, with the popup above it (OWNER, 5 October 2026): as soon as the field is focused (and as
 * more is typed), names already used before appear with the price they were last used at. Clicking one (or arrow keys +
 * Enter) fills the description and its price; carrying on typing, with the same name or a different one,
 * just works -- nothing is forced. The popup is drawn on the page itself (not inside the table), so a
 * scrolling table can never clip it, and it opens above the field unless there is no room there.
 */
export function LineDescriptionInput({
  value,
  suggestions,
  onChange,
  onPick,
}: {
  value: string;
  suggestions: readonly LineSuggestion[];
  onChange: (text: string) => void;
  onPick: (suggestion: LineSuggestion) => void;
}) {
  const listId = useId();
  const ref = useRef<HTMLInputElement>(null);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [active, setActive] = useState(-1);
  const [position, setPosition] = useState<PopupPosition | null>(null);

  const matches = matchSuggestions(value, suggestions);
  const open = focused && !dismissed && matches.length > 0;

  useLayoutEffect(() => {
    if (!open || !ref.current) return;
    function place() {
      if (!ref.current) return;
      const rect = ref.current.getBoundingClientRect();
      const width = Math.max(rect.width, 280);
      const left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
      const needed = 40 + matches.length * 44;
      setPosition(
        rect.top > needed
          ? { left, width, bottom: window.innerHeight - rect.top + 4 }
          : { left, width, top: rect.bottom + 4 },
      );
    }
    place();
    window.addEventListener("resize", place);
    window.addEventListener("scroll", place, true);
    return () => {
      window.removeEventListener("resize", place);
      window.removeEventListener("scroll", place, true);
    };
  }, [open, matches.length]);

  function pick(suggestion: LineSuggestion) {
    onPick(suggestion);
    setDismissed(true);
  }

  return (
    <>
      <input
        ref={ref}
        type="text"
        maxLength={500}
        value={value}
        placeholder="Deskripsi baris"
        autoComplete="off"
        role="combobox"
        aria-expanded={open}
        aria-controls={open ? listId : undefined}
        aria-autocomplete="list"
        onChange={(event) => {
          setDismissed(false);
          setActive(-1);
          onChange(event.target.value);
        }}
        onFocus={() => setFocused(true)}
        onBlur={() => setFocused(false)}
        onKeyDown={(event) => {
          if (!open) return;
          if (event.key === "ArrowDown") {
            event.preventDefault();
            setActive((index) => (index + 1) % matches.length);
          } else if (event.key === "ArrowUp") {
            event.preventDefault();
            setActive((index) => (index <= 0 ? matches.length - 1 : index - 1));
          } else if (event.key === "Enter" && active >= 0) {
            event.preventDefault();
            pick(matches[active]);
          } else if (event.key === "Escape") {
            setDismissed(true);
          }
        }}
      />
      {open && position
        ? createPortal(
            <div
              className="line-suggest"
              style={{
                left: position.left,
                width: position.width,
                top: position.top,
                bottom: position.bottom,
              }}
            >
              <p className="line-suggest-title">
                {value.trim() === ""
                  ? "Pilih yang sudah ada, atau ketik nama baru."
                  : "Sudah pernah ada. Klik untuk memakai, atau lanjut mengetik."}
              </p>
              <ul id={listId} role="listbox">
                {matches.map((item, index) => (
                  <li
                    key={item.description}
                    role="option"
                    aria-selected={index === active}
                    className={
                      index === active ? "line-suggest-item is-active" : "line-suggest-item"
                    }
                    // mouse down (not click) so the field does not lose focus and close the popup first
                    onMouseDown={(event) => {
                      event.preventDefault();
                      pick(item);
                    }}
                  >
                    <span className="line-suggest-name">{item.description}</span>
                    <span className="line-suggest-price">
                      {item.unit_price !== ""
                        ? `Harga terakhir ${formatPlain(item.unit_price)}`
                        : ""}
                    </span>
                  </li>
                ))}
              </ul>
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
