"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
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
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddContactDrawer } from "@/features/contacts/QuickAddContactDrawer";
import { QuickAddPaymentLinkDrawer } from "./QuickAddPaymentLinkDrawer";
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
  paymentLinks = [],
  entity,
  today,
  initial,
}: {
  customers: readonly ContactRow[];
  accounts: readonly MoneyControlRow[];
  categories: readonly CategoryRow[];
  /** Descriptions used before, for the popup above each line's description (OWNER, 5 October 2026). */
  suggestions?: readonly LineSuggestion[];
  /** The active payment links (Tautan Pembayaran, decision 307) offered below the receiving account. */
  paymentLinks?: readonly { id: string; name: string }[];
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
    payment_channel_id?: string | null;
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
  const [newCustomerName, setNewCustomerName] = useState("");
  // Same idea for payment links: a link added on the spot is appended and selected without losing the lines.
  const [linkList, setLinkList] = useState<{ id: string; name: string }[]>(
    paymentLinks.map((l) => ({ id: l.id, name: l.name })),
  );
  const [linkId, setLinkId] = useState(initial?.payment_channel_id ?? "");
  const [addingLink, setAddingLink] = useState(false);

  return (
    <>
      <form {...actionForm} className="record-form record-form-wide">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, "invoice")} />
        {initial ? (
          <>
            <input type="hidden" name="invoice_id" value={initial.id} />
            <input type="hidden" name="version" value={initial.version} />
          </>
        ) : null}

        <ContactPicker
          label="Pelanggan"
          name="customer_id"
          noun="pelanggan"
          contacts={customerList}
          value={customerId}
          onChange={setCustomerId}
          onAddNew={(typedName) => {
            setNewCustomerName(typedName);
            setAddingCustomer(true);
          }}
        />
        <label>
          Tanggal Invoice
          <input
            type="date"
            name="issue_date"
            required
            defaultValue={initial?.issue_date ?? today}
          />
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
        <label>
          Tautan Pembayaran (opsional)
          <select
            name="payment_channel_id"
            value={linkId}
            onChange={(event) => setLinkId(event.target.value)}
          >
            <option value="">— Tanpa tautan —</option>
            {linkList.map((link) => (
              <option key={link.id} value={link.id}>
                {link.name}
              </option>
            ))}
          </select>
        </label>
        <p className="hint">
          Pelanggan bisa menekan tombol “Bayar sekarang” di invoice untuk membuka halaman
          pembayaran.{" "}
          <button type="button" className="btn-ghost" onClick={() => setAddingLink(true)}>
            + Tambah tautan baru
          </button>
        </p>

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
      {/* Outside the form on purpose: a form inside a form is invalid HTML, and the panel's own Save button
        was submitting the invoice instead of the new customer. */}
      <QuickAddPaymentLinkDrawer
        entity={entity}
        open={addingLink}
        onClose={() => setAddingLink(false)}
        onCreated={(link) => {
          setLinkList((list) => [...list, link]);
          setLinkId(link.id);
          setAddingLink(false);
        }}
      />
      <QuickAddContactDrawer
        contactKind="customer"
        entity={entity}
        initialName={newCustomerName}
        open={addingCustomer}
        onClose={() => setAddingCustomer(false)}
        onCreated={(contact) => {
          setCustomerList((list) => [...list, contact]);
          setCustomerId(contact.id);
          setAddingCustomer(false);
        }}
      />
    </>
  );
}
