"use client";

import { useEffect, useId, useRef, useState } from "react";
import { exactTypeahead, hasTyped, matchTypeahead } from "@/domain/shared/typeahead";

export interface PickableContact {
  id: string;
  display_name: string;
}

const MAX_SHOWN = 8;

/** What to offer for what has been typed: names that start with it first, then (from two characters) names that
 * contain it. Nothing typed yet: nothing -- the list opens when the person starts typing, not when the field is
 * clicked (OWNER, 6 October 2026; `@/domain/shared/typeahead`). */
export function matchContacts(
  typed: string,
  all: readonly PickableContact[],
  limit = MAX_SHOWN,
): PickableContact[] {
  return matchTypeahead(typed, all, (item) => item.display_name, limit);
}

/**
 * Customer / vendor field you can type in (OWNER, 5 October 2026): start typing and the names that match appear
 * (nothing opens just because the field was clicked, OWNER, 6 October 2026), the list narrows as more is typed, then
 * click one or press Enter. A name that is not on file offers
 * "+ Tambah ... baru" as the last row (`onAddNew`, with what was typed), so adding someone never means leaving
 * the form. The chosen contact travels in a hidden input named `name`; the visible field only searches.
 */
export function ContactPicker({
  label,
  name,
  contacts,
  noun,
  value,
  defaultValue = "",
  optional = false,
  onChange,
  onAddNew,
}: {
  /** The visible field label, e.g. "Pelanggan". */
  label: string;
  name: string;
  contacts: readonly PickableContact[];
  /** "pelanggan" or "vendor", used in the hints. */
  noun: string;
  /** Controlled selection (a contact id, "" for none); leave undefined for an uncontrolled field. */
  value?: string;
  defaultValue?: string;
  /** The field may stay empty (an expense without a registered vendor). Typed text that matches no one still
   * has to be resolved -- pick, add, or clear it -- so a half-typed name is never silently dropped. */
  optional?: boolean;
  onChange?: (id: string) => void;
  /** Called with the typed text when the person chooses "+ Tambah ... baru". Omit to hide that row. */
  onAddNew?: (typedName: string) => void;
}) {
  const listId = useId();
  const inputId = useId();
  const inputRef = useRef<HTMLInputElement>(null);
  const [inner, setInner] = useState(defaultValue);
  const selectedId = value ?? inner;
  const selected = contacts.find((contact) => contact.id === selectedId);
  // What the person has typed; null means "show the chosen contact's name".
  const [typedText, setTypedText] = useState<string | null>(null);
  const text = typedText ?? selected?.display_name ?? "";
  // A contact chosen from outside (just added through the quick-add panel) shows its name in the field.
  const [seenId, setSeenId] = useState(selectedId);
  if (seenId !== selectedId) {
    setSeenId(selectedId);
    if (selectedId !== "") setTypedText(null);
  }
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [active, setActive] = useState(-1);

  // The browser's own "required" check cannot see a hidden input, so the visible field carries the message.
  useEffect(() => {
    const unresolved = selectedId === "" && (!optional || hasTyped(typedText ?? ""));
    inputRef.current?.setCustomValidity(
      unresolved
        ? optional
          ? `Pilih ${noun} dari daftar, tambah ${noun} baru, atau kosongkan kolom ini.`
          : `Pilih ${noun} dari daftar, atau tambah ${noun} baru.`
        : "",
    );
  }, [selectedId, noun, optional, typedText]);

  const matches = matchContacts(text, contacts);
  const exact = exactTypeahead(text, contacts, (contact) => contact.display_name);
  const showAdd = onAddNew !== undefined && hasTyped(text) && !exact;
  const rowCount = matches.length + (showAdd ? 1 : 0);
  // Open only once something has been typed: clicking into the field, or into a field that already shows its
  // chosen name, shows no list (OWNER, 6 October 2026).
  const open = focused && !dismissed && typedText !== null && hasTyped(typedText);

  function select(contact: PickableContact) {
    setInner(contact.id);
    setTypedText(null);
    setDismissed(true);
    setActive(-1);
    onChange?.(contact.id);
  }

  function addNew() {
    setDismissed(true);
    setActive(-1);
    onAddNew?.(text.trim());
  }

  function chooseRow(index: number) {
    if (index < matches.length) select(matches[index]);
    else if (showAdd) addNew();
  }

  return (
    <div className="contact-picker-field">
      <label htmlFor={inputId}>{label}</label>
      <div className="contact-picker">
        <input type="hidden" name={name} value={selectedId} />
        <input
          ref={inputRef}
          id={inputId}
          type="text"
          value={text}
          maxLength={200}
          autoComplete="off"
          placeholder={`Ketik nama ${noun}`}
          role="combobox"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          aria-autocomplete="list"
          onChange={(event) => {
            setTypedText(event.target.value);
            setDismissed(false);
            setActive(-1);
            // Typing again drops the earlier choice until a name is picked (or matches exactly on leaving).
            if (selectedId !== "") {
              setInner("");
              onChange?.("");
            }
          }}
          onFocus={() => {
            setFocused(true);
            setDismissed(false);
          }}
          onBlur={() => {
            setFocused(false);
            if (selectedId === "" && exact) select(exact);
          }}
          onKeyDown={(event) => {
            if (event.key === "ArrowDown") {
              event.preventDefault();
              setDismissed(false);
              setActive((index) => (rowCount === 0 ? -1 : (index + 1) % rowCount));
            } else if (event.key === "ArrowUp") {
              event.preventDefault();
              setActive((index) => (rowCount === 0 ? -1 : index <= 0 ? rowCount - 1 : index - 1));
            } else if (event.key === "Enter" && open) {
              if (active >= 0) {
                event.preventDefault();
                chooseRow(active);
              } else if (exact) {
                event.preventDefault();
                select(exact);
              } else if (matches.length === 1) {
                event.preventDefault();
                select(matches[0]);
              } else if (selectedId === "") {
                // Never submit the whole form just because Enter was pressed on an unchosen name.
                event.preventDefault();
              }
            } else if (event.key === "Escape") {
              setDismissed(true);
            }
          }}
        />
        {open ? (
          <div className="contact-picker-list">
            {matches.length === 0 ? (
              <p className="line-suggest-title">
                {contacts.length === 0
                  ? `Belum ada ${noun}. Tambahkan yang pertama di bawah.`
                  : `Tidak ada ${noun} dengan huruf itu.`}
              </p>
            ) : (
              <ul id={listId} role="listbox">
                {matches.map((contact, index) => (
                  <li
                    key={contact.id}
                    role="option"
                    aria-selected={index === active}
                    className={
                      index === active ? "line-suggest-item is-active" : "line-suggest-item"
                    }
                    // mouse down (not click) so the field keeps focus and the list does not close first
                    onMouseDown={(event) => {
                      event.preventDefault();
                      select(contact);
                    }}
                  >
                    <span className="line-suggest-name">{contact.display_name}</span>
                  </li>
                ))}
              </ul>
            )}
            {showAdd ? (
              <button
                type="button"
                className={
                  active === matches.length ? "contact-picker-add is-active" : "contact-picker-add"
                }
                onMouseDown={(event) => {
                  event.preventDefault();
                  addNew();
                }}
              >
                {`+ Tambah “${text.trim()}” sebagai ${noun} baru`}
              </button>
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  );
}
