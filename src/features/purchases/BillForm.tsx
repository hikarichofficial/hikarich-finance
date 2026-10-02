"use client";

import { useActionState, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { ContactRow } from "@/schemas/contacts";
import {
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { createBillAction, idleBillActionState } from "./actions";

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
  entity,
  today,
}: {
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  entity: string | undefined;
  today: string;
}) {
  const [state, action, pending] = useActionState(createBillAction, idleBillActionState);
  const [rows, setRows] = useState<RecurringLineRow[]>([newRecurringLineRow(1)]);

  return (
    <form action={action} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "bill")} />

      <label>
        Vendor
        <select name="vendor_id" required defaultValue="">
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
        <input name="vendor_reference" maxLength={100} />
      </label>
      <label>
        Tanggal Tagihan
        <input type="date" name="bill_date" required defaultValue={today} />
      </label>
      <label>
        Jatuh Tempo
        <input type="date" name="due_date" required defaultValue={today} />
      </label>

      <RecurringLinesEditor
        kind="bill"
        categories={categories}
        rows={rows}
        onChange={setRows}
        taxFields
      />
      <p className="hint">
        Potongan PPh dan PPN dihitung otomatis dari isian pajak tiap baris dan data pajak vendor. Hasilnya
        terlihat di halaman tagihan sebelum disetujui.
      </p>

      <label>
        Catatan (opsional)
        <textarea name="notes" maxLength={2000} />
      </label>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan sebagai Draf"}
      </button>
    </form>
  );
}
