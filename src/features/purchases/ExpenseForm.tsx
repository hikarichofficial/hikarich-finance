"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { LineSuggestion } from "@/domain/sales/lineSuggestions";
import type { ContactRow } from "@/schemas/contacts";
import type { MoneyControlRow } from "@/schemas/money";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { createExpenseAction } from "./expenseActions";
import { idleExpenseActionState } from "./expenseActionsState";

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
  suggestions = [],
  entity,
  today,
  initial,
}: {
  accounts: readonly MoneyControlRow[];
  vendors: readonly ContactRow[];
  categories: readonly CategoryRow[];
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
  entity: string | undefined;
  today: string;
  /** Present when editing an existing draft: the same form saves through `update_expense_draft`. */
  initial?: {
    id: string;
    version: number;
    payee_id: string | null;
    payee_name: string | null;
    account_id: string;
    expense_date: string;
    receipt_reference: string | null;
    notes: string | null;
    lines: readonly Record<string, unknown>[];
  };
}) {
  const [state, action, pending] = useActionState(createExpenseAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );
  const [payeeId, setPayeeId] = useState(initial?.payee_id ?? "");

  return (
    <form {...actionForm} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "expense")} />
      {initial ? (
        <>
          <input type="hidden" name="expense_id" value={initial.id} />
          <input type="hidden" name="version" value={initial.version} />
        </>
      ) : null}

      <label>
        Dibayar dari Rekening
        <select name="account_id" required defaultValue={initial?.account_id ?? ""}>
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
        <input
          type="date"
          name="expense_date"
          required
          defaultValue={initial?.expense_date ?? today}
        />
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
          <input
            name="payee_name"
            required
            maxLength={200}
            placeholder="mis. Toko Bangunan Jaya"
            defaultValue={initial?.payee_name ?? ""}
          />
        </label>
      ) : null}
      <label>
        Nomor Struk / Nota (opsional)
        <input
          name="receipt_reference"
          maxLength={100}
          defaultValue={initial?.receipt_reference ?? ""}
        />
      </label>

      <RecurringLinesEditor
        kind="expense"
        categories={categories}
        suggestions={suggestions}
        rows={rows}
        onChange={setRows}
        taxFields
      />

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
