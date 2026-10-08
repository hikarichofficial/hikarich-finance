"use client";

import { useId, useLayoutEffect, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { formatPlain } from "@/domain/money/format";
import { browseTypeahead, hasTyped } from "@/domain/shared/typeahead";
import {
  exactSuggestion,
  matchSuggestions,
  type LineSuggestion,
} from "@/domain/sales/lineSuggestions";

interface PopupPosition {
  left: number;
  width: number;
  top?: number;
  bottom?: number;
}

/**
 * The description of a line, with the popup above it (OWNER, 5 October 2026): names already used before appear with
 * the price they were last used at. Since 6 October 2026 the popup waits for the first typed character -- clicking
 * into the field shows nothing -- then follows what is typed and narrows as it gets longer. Clicking a name (or arrow
 * keys + Enter) fills the description and its price; carrying on typing, with the same name or a different one,
 * just works -- nothing is forced. A name not on file offers "+ Tambah ... sebagai deskripsi baru" as the last row,
 * like a customer does: it keeps the typed text, which is remembered with the document and offered from then on.
 * The popup is drawn on the page itself (not inside the table), so a scrolling table can never clip it, and it opens
 * above the field unless there is no room there.
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

  // An empty field lists the descriptions used before (OWNER, 8 October 2026); typing narrows the list.
  const typed = hasTyped(value);
  const matches = typed
    ? matchSuggestions(value, suggestions)
    : browseTypeahead("", suggestions, (item) => item.description, 6, 12);
  const showAdd = typed && exactSuggestion(value, suggestions) === undefined;
  const rowCount = matches.length + (showAdd ? 1 : 0);
  const open = focused && !dismissed && (typed || suggestions.length > 0);

  useLayoutEffect(() => {
    if (!open || !ref.current) return;
    function place() {
      if (!ref.current) return;
      const rect = ref.current.getBoundingClientRect();
      const width = Math.max(rect.width, 280);
      const left = Math.max(8, Math.min(rect.left, window.innerWidth - width - 8));
      const needed = 72 + Math.max(1, rowCount) * 44;
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
  }, [open, rowCount]);

  function pick(suggestion: LineSuggestion) {
    onPick(suggestion);
    setDismissed(true);
  }

  // "+ Tambah ... baru": the typed text stays as it is; it is remembered once the document is saved.
  function addNew() {
    setDismissed(true);
    setActive(-1);
  }

  function chooseRow(index: number) {
    if (index < matches.length) pick(matches[index]);
    else if (showAdd) addNew();
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
        onFocus={() => {
          setFocused(true);
          setDismissed(false);
        }}
        onClick={() => setDismissed(false)}
        onBlur={() => setFocused(false)}
        onKeyDown={(event) => {
          if (!open || rowCount === 0) return;
          if (event.key === "ArrowDown") {
            event.preventDefault();
            setActive((index) => (index + 1) % rowCount);
          } else if (event.key === "ArrowUp") {
            event.preventDefault();
            setActive((index) => (index <= 0 ? rowCount - 1 : index - 1));
          } else if (event.key === "Enter" && active >= 0) {
            event.preventDefault();
            chooseRow(active);
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
                {matches.length > 0
                  ? typed
                    ? "Sesuai huruf yang diketik. Klik untuk memakai, atau lanjut mengetik."
                    : "Pernah dipakai. Klik untuk memakai, atau mulai mengetik."
                  : suggestions.length === 0
                    ? "Belum ada deskripsi tersimpan. Pilih “+ Tambah” di bawah untuk memakai tulisan ini; deskripsi yang sudah dipakai akan muncul di sini lain kali."
                    : "Tidak ada deskripsi dengan huruf ini. Pilih “+ Tambah” di bawah, atau lanjutkan mengetik."}
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
              {showAdd ? (
                <button
                  type="button"
                  className={
                    active === matches.length
                      ? "contact-picker-add is-active"
                      : "contact-picker-add"
                  }
                  // mouse down (not click) so the field does not lose focus and close the popup first
                  onMouseDown={(event) => {
                    event.preventDefault();
                    addNew();
                  }}
                >
                  {`+ Tambah “${value.trim()}” sebagai deskripsi baru`}
                </button>
              ) : null}
            </div>,
            document.body,
          )
        : null}
    </>
  );
}
