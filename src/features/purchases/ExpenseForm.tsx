"use client";

import { useActionState, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { ContactRow } from "@/schemas/contacts";
import type { MoneyControlRow } from "@/schemas/money";
import {
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { createExpenseAction, idleExpenseActionState } from "./expenseActions";

/**
 * Record Expense (Step 09 §12/§22: "Amount → payee/category/account → receipt → confirm", decision 245).
 * Creates a draft through `create_expense_draft`; confirming (posting) is the next step on its Detail page,
 * so a mistyped amount never reaches the ledger in the same click. Lines reuse `RecurringLinesEditor` with
 * kind `expense`, whose category/treatment pairing is exactly what `purchase_prepare_lines` validates.
 */
export function ExpenseForm({
  accounts,
  vendors,
  categories,
  entity,
  today,
}: {
  accounts: readonly MoneyControlRow[];
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  entity: string | undefined;
  today: string;
}) {
  const [state, action, pending] = useActionState(createExpenseAction, idleExpenseActionState);
  const [rows, setRows] = useState<RecurringLineRow[]>([newRecurringLineRow(1)]);
  const [payeeId, setPayeeId] = useState("");

  return (
    <form action={action} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "expense")} />

      <label>
        Dibayar dari Rekening
        <select name="account_id" required defaultValue="">
          <option value="" disabled>
            Pilih rekening kas/bank
          </option>
          {accounts.map((account) => (
            <option key={account.financial_account_id} value={account.financial_account_id}>
              {account.name} ({account.currency})
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal
        <input type="date" name="expense_date" required defaultValue={today} />
      </label>
      <label>
        Vendor (opsional)
        <select name="payee_id" value={payeeId} onChange={(e) => setPayeeId(e.target.value)}>
          <option value="">— Bukan vendor terdaftar —</option>
          {vendors.map((vendor) => (
            <option key={vendor.id} value={vendor.id}>
              {vendor.display_name}
            </option>
          ))}
        </select>
      </label>
      {payeeId === "" ? (
        <label>
          Nama Penerima
          <input name="payee_name" required maxLength={200} placeholder="mis. Toko Bangunan Jaya" />
        </label>
      ) : null}
      <label>
        Nomor Struk / Nota (opsional)
        <input name="receipt_reference" maxLength={100} />
      </label>

      <RecurringLinesEditor kind="expense" categories={categories} rows={rows} onChange={setRows} />

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
