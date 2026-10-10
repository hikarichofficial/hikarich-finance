"use client";

import { ContactPicker } from "@/features/contacts/ContactPicker";

/**
 * The Picker (OWNER, 10 October 2026, who named it): a field you can click to see the whole list, type to
 * narrow it, and pick with a click or Enter -- with "+ Tambah ... baru" as the last row when adding is
 * allowed. The OWNER asked for one name for this behaviour so it can be asked for by name rather than
 * described each time, and this is it.
 *
 * It is the customer/vendor field's behaviour, generalised: anything with an id and a label can use it, not
 * only contacts. The implementation still lives in `ContactPicker`, which is where it grew (decisions from 5
 * and 8 October); this wraps it rather than moving it, so the twenty-odd screens already calling
 * `ContactPicker` are left untouched. Inverting the two -- the generic one owning the behaviour, the contact
 * one wrapping it -- is a tidy-up worth doing on its own, not in the middle of a feature.
 */

export interface PickableItem {
  id: string;
  label: string;
}

export function Picker({
  label,
  name,
  items,
  noun,
  value,
  defaultValue = "",
  optional = false,
  onChange,
  onAddNew,
}: {
  /** The visible field label, e.g. "Kategori". */
  label: string;
  /** The form field the chosen id travels in. */
  name: string;
  items: readonly PickableItem[];
  /** What one entry is, in the hints: "kategori", "akun". */
  noun: string;
  /** Controlled selection (an id, "" for none); omit for an uncontrolled field. */
  value?: string;
  defaultValue?: string;
  /** The field may stay empty. Typed text that matches nothing still has to be resolved. */
  optional?: boolean;
  onChange?: (id: string) => void;
  /** Called with the typed text when "+ Tambah ... baru" is chosen. Omit to hide that row. */
  onAddNew?: (typedName: string) => void;
}) {
  return (
    <ContactPicker
      label={label}
      name={name}
      contacts={items.map((item) => ({ id: item.id, display_name: item.label }))}
      noun={noun}
      value={value}
      defaultValue={defaultValue}
      optional={optional}
      onChange={onChange}
      onAddNew={onAddNew}
    />
  );
}
