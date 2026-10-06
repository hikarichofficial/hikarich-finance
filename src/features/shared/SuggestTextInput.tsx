"use client";

import { useId, useState, type ReactNode } from "react";
import { exactTypeahead, hasTyped, matchTypeahead } from "@/domain/shared/typeahead";

const MAX_SHOWN = 8;

/**
 * A text field you type in, with the names used before offered as you type (OWNER, 6 October 2026: the recipient of
 * an expense is typed by hand, "akan muncul popup yang sesuai ketikan, dan akan bisa diklik dipilih"). It works like
 * the customer / vendor field on an invoice (`ContactPicker`): nothing opens when the field is only clicked, the list
 * appears from the first typed character and narrows as more is typed, an entry is picked by click or arrow keys +
 * Enter, and a name that is not on file offers "+ Tambah ... baru" as the last row.
 *
 * The difference is what "add" means. A contact is a record of its own; a recipient's name or a description is not --
 * it is remembered through the documents it is saved on. So "+ Tambah" keeps the typed text as the new entry and says
 * so; it appears in the list from the next time. The typed text is what is submitted, whether picked or not.
 */
export function SuggestTextInput({
  label,
  name,
  suggestions,
  noun,
  defaultValue = "",
  required = false,
  maxLength = 200,
  placeholder,
}: {
  /** The visible field label, e.g. "Nama Penerima". */
  label: ReactNode;
  name: string;
  /** Names used before, most recent first (already de-duplicated). */
  suggestions: readonly string[];
  /** "penerima", used in the "+ Tambah ... baru" row and the hints. */
  noun: string;
  defaultValue?: string;
  required?: boolean;
  maxLength?: number;
  placeholder?: string;
}) {
  const listId = useId();
  const inputId = useId();
  const [text, setText] = useState(defaultValue);
  // Whether the person has typed since the field was last focused or a name was last chosen: a field that already
  // holds a saved name must not open its list just because it was clicked.
  const [edited, setEdited] = useState(false);
  const [focused, setFocused] = useState(false);
  const [dismissed, setDismissed] = useState(false);
  const [active, setActive] = useState(-1);
  const [added, setAdded] = useState<string | null>(null);

  const matches = matchTypeahead(text, suggestions, (item) => item, MAX_SHOWN);
  const exact = exactTypeahead(text, suggestions, (item) => item);
  const showAdd = hasTyped(text) && exact === undefined;
  const rowCount = matches.length + (showAdd ? 1 : 0);
  const open = focused && !dismissed && edited && hasTyped(text) && rowCount > 0;

  function select(value: string) {
    setText(value);
    setEdited(false);
    setDismissed(true);
    setActive(-1);
    setAdded(null);
  }

  function addNew() {
    setAdded(text.trim());
    setEdited(false);
    setDismissed(true);
    setActive(-1);
  }

  function chooseRow(index: number) {
    if (index < matches.length) select(matches[index]);
    else if (showAdd) addNew();
  }

  return (
    <div className="contact-picker-field">
      <label htmlFor={inputId}>{label}</label>
      <div className="contact-picker">
        <input
          id={inputId}
          name={name}
          type="text"
          value={text}
          required={required}
          maxLength={maxLength}
          autoComplete="off"
          placeholder={placeholder}
          role="combobox"
          aria-expanded={open}
          aria-controls={open ? listId : undefined}
          aria-autocomplete="list"
          onChange={(event) => {
            setText(event.target.value);
            setEdited(true);
            setDismissed(false);
            setActive(-1);
            setAdded(null);
          }}
          onFocus={() => setFocused(true)}
          onBlur={() => setFocused(false)}
          onKeyDown={(event) => {
            if (!open) return;
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
        {open ? (
          <div className="contact-picker-list">
            {matches.length === 0 ? (
              <p className="line-suggest-title">
                {suggestions.length === 0
                  ? `Belum ada ${noun} tersimpan. Pilih “+ Tambah” di bawah untuk memakai tulisan ini; ${noun} yang sudah dipakai akan muncul di sini lain kali.`
                  : `Tidak ada ${noun} dengan huruf itu. Pilih “+ Tambah” di bawah, atau lanjutkan mengetik.`}
              </p>
            ) : (
              <ul id={listId} role="listbox">
                {matches.map((item, index) => (
                  <li
                    key={item}
                    role="option"
                    aria-selected={index === active}
                    className={
                      index === active ? "line-suggest-item is-active" : "line-suggest-item"
                    }
                    // mouse down (not click) so the field keeps focus and the list does not close first
                    onMouseDown={(event) => {
                      event.preventDefault();
                      select(item);
                    }}
                  >
                    <span className="line-suggest-name">{item}</span>
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
      {added !== null && added === text.trim() ? (
        <p className="hint" role="status">
          {`“${added}” dipakai sebagai ${noun} baru. Tersimpan bersama dokumen ini dan muncul di pilihan berikutnya.`}
        </p>
      ) : null}
    </div>
  );
}
