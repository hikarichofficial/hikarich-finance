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
import { QuickAddContactDrawer } from "@/features/contacts/QuickAddContactDrawer";
import { createInvoiceAction } from "./actions";
import { idleInvoiceActionState } from "./actionsState";

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
  suggestions = [],
  entity,
  today,
  initial,
}: {
  customers: readonly ContactRow[];
  accounts: readonly MoneyControlRow[];
  categories: readonly CategoryRow[];
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
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
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<RecurringLineRow[]>(
    initial && initial.lines.length > 0
      ? buildInitialRecurringLines(initial.lines)
      : [newRecurringLineRow(1)],
  );
  // Local copy so a quick-added customer (owner, 4 October 2026) can be appended and selected right away,
  // without reloading the page and losing the lines already typed in below. Only what the dropdown needs
  // to render (id + name) -- a quick add never returns the other ContactRow fields, and none are used here.
  const [customerList, setCustomerList] = useState<{ id: string; display_name: string }[]>(
    customers.map((c) => ({ id: c.id, display_name: c.display_name })),
  );
  const [customerId, setCustomerId] = useState(initial?.customer_id ?? "");
  const [addingCustomer, setAddingCustomer] = useState(false);

  return (
    <form {...actionForm} className="record-form record-form-wide">
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
        <select
          name="customer_id"
          required
          value={customerId}
          onChange={(event) => setCustomerId(event.target.value)}
        >
          <option value="" disabled>
            Pilih pelanggan
          </option>
          {customerList.map((customer) => (
            <option key={customer.id} value={customer.id}>
              {customer.display_name}
            </option>
          ))}
        </select>
        <button type="button" className="btn-ghost" onClick={() => setAddingCustomer(true)}>
          + Tambah pelanggan baru
        </button>
      </label>
      <QuickAddContactDrawer
        contactKind="customer"
        entity={entity}
        open={addingCustomer}
        onClose={() => setAddingCustomer(false)}
        onCreated={(contact) => {
          setCustomerList((list) => [...list, contact]);
          setCustomerId(contact.id);
          setAddingCustomer(false);
        }}
      />
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
        suggestions={suggestions}
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
