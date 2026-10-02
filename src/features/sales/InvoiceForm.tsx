"use client";

import { useActionState, useState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { ContactRow } from "@/schemas/contacts";
import type { MoneyControlRow } from "@/schemas/money";
import {
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  newRecurringLineRow,
  RecurringLinesEditor,
  type RecurringLineRow,
} from "@/features/planning/RecurringLinesEditor";
import { createInvoiceAction, idleInvoiceActionState } from "./actions";

/**
 * Create Invoice (Step 09 §11, decision 257): a draft through `create_invoice_draft`. Issuing (which
 * numbers it, posts it and recognises its tax) stays on the Invoice Detail page. Lines reuse
 * `RecurringLinesEditor` with kind `invoice` and its tax field (the VAT treatment the P7 engine reads from
 * the line). The receiving account is optional and only printed on the invoice as the place to pay.
 */
export function InvoiceForm({
  customers,
  accounts,
  categories,
  entity,
  today,
  initial,
}: {
  customers: readonly ContactRow[];
  accounts: readonly MoneyControlRow[];
  categories: readonly CategoryRow[];
  entity: string | undefined;
  today: string;
  /** Present when editing an existing draft (decision 261): the same form saves through
   * `update_invoice_draft`. */
  initial?: {
    id: string;
    version: number;
    customer_id: string;
    issue_date: string;
    due_date: string;
    payment_account_id: string | null;
    notes: string | null;
    terms: string | null;
    lines: readonly Record<string, unknown>[];
  };
}) {
  const [state, action, pending] = useActionState(createInvoiceAction, idleInvoiceActionState);
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );

  return (
    <form action={action} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "invoice")} />
      {initial ? (
        <>
          <input type="hidden" name="invoice_id" value={initial.id} />
          <input type="hidden" name="version" value={initial.version} />
        </>
      ) : null}

      <label>
        Pelanggan
        <select name="customer_id" required defaultValue={initial?.customer_id ?? ""}>
          <option value="" disabled>
            Pilih pelanggan
          </option>
          {customers.map((customer) => (
            <option key={customer.id} value={customer.id}>
              {customer.display_name}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal Invoice
        <input type="date" name="issue_date" required defaultValue={initial?.issue_date ?? today} />
      </label>
      <label>
        Jatuh Tempo
        <input type="date" name="due_date" required defaultValue={initial?.due_date ?? today} />
      </label>
      <label>
        Rekening Tujuan Pembayaran (opsional)
        <select name="payment_account_id" defaultValue={initial?.payment_account_id ?? ""}>
          <option value="">— Tidak dicantumkan —</option>
          {accounts.map((account) => (
            <option key={account.financial_account_id} value={account.financial_account_id}>
              {account.name} ({account.currency})
            </option>
          ))}
        </select>
      </label>

      <RecurringLinesEditor
        kind="invoice"
        categories={categories}
        rows={rows}
        onChange={setRows}
        taxFields
      />

      <label>
        Catatan untuk Pelanggan (opsional)
        <textarea name="notes" maxLength={2000} defaultValue={initial?.notes ?? ""} />
      </label>
      <label>
        Syarat & Ketentuan (opsional)
        <textarea name="terms" maxLength={4000} defaultValue={initial?.terms ?? ""} />
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
