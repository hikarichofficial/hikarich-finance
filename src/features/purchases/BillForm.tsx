"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { LineSuggestion } from "@/domain/sales/lineSuggestions";
import type { ContactRow } from "@/schemas/contacts";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { createBillAction } from "./actions";
import { idleBillActionState } from "./actionsState";

/**
 * Record Bill (Step 09 §12, decision 257): the vendor's invoice as a draft through `create_bill_draft`.
 * Submitting and approving (which posts it and recognises its tax) stay on the Bill Detail page, so a
 * mistyped amount never reaches the ledger in the same click. Lines reuse `RecurringLinesEditor` with
 * kind `bill` and its tax fields: the withholding object, the VAT the vendor charged and the tax-invoice
 * number are facts the P7 engine reads from the line; the engine, not this form, decides the tax.
 */
export function BillForm({
  vendors,
  categories,
  suggestions = [],
  entity,
  today,
  initial,
}: {
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
  entity: string | undefined;
  today: string;
  /** Present when editing an existing draft (decision 261): the same form saves through `update_bill_draft`. */
  initial?: {
    id: string;
    version: number;
    vendor_id: string;
    vendor_reference: string | null;
    bill_date: string;
    due_date: string;
    notes: string | null;
    lines: readonly Record<string, unknown>[];
  };
}) {
  const [state, action, pending] = useActionState(createBillAction, idleBillActionState);
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );

  return (
    <form {...actionForm} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "bill")} />
      {initial ? (
        <>
          <input type="hidden" name="bill_id" value={initial.id} />
          <input type="hidden" name="version" value={initial.version} />
        </>
      ) : null}

      <label>
        Vendor
        <select name="vendor_id" required defaultValue={initial?.vendor_id ?? ""}>
          <option value="" disabled>
            Pilih vendor
          </option>
          {vendors.map((vendor) => (
            <option key={vendor.id} value={vendor.id}>
              {vendor.display_name}
            </option>
          ))}
        </select>
      </label>
      <label>
        Nomor Invoice dari Vendor (opsional)
        <input
          name="vendor_reference"
          maxLength={100}
          defaultValue={initial?.vendor_reference ?? ""}
        />
      </label>
      <label>
        Tanggal Tagihan
        <input type="date" name="bill_date" required defaultValue={initial?.bill_date ?? today} />
      </label>
      <label>
        Jatuh Tempo
        <input type="date" name="due_date" required defaultValue={initial?.due_date ?? today} />
      </label>

      <RecurringLinesEditor
        kind="bill"
        categories={categories}
        suggestions={suggestions}
        rows={rows}
        onChange={setRows}
        taxFields
      />
      <p className="hint">
        Potongan PPh dan PPN dihitung otomatis dari isian pajak tiap baris dan data pajak vendor.
        Hasilnya terlihat di halaman tagihan sebelum disetujui.
      </p>

      <label>
        Catatan (opsional)
        <textarea name="notes" maxLength={2000} defaultValue={initial?.notes ?? ""} />
      </label>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : initial ? "Simpan Perubahan" : "Simpan sebagai Draf"}
      </button>
    </form>
  );
}
