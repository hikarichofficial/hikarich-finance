"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddContactDrawer } from "@/features/contacts/QuickAddContactDrawer";
import { QuickAddCategoryDrawer } from "@/features/categories/QuickAddCategoryDrawer";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { SuggestTextInput } from "@/features/shared/SuggestTextInput";
import { formatMoney } from "@/domain/money/format";
import { incomeTaxNote } from "@/domain/sales/income";
import { recordIncomeAction, reverseIncomeAction, type IncomeActionState } from "./incomeActions";

const IDLE: IncomeActionState = { status: "idle" };

export interface IncomeCategoryChoice {
  id: string;
  name: string;
  /** What the income is booked under, in the chart of accounts; null for a category just added. */
  accountName: string | null;
  inTurnover: boolean;
}

export interface IncomeAccountChoice {
  id: string;
  label: string;
  name: string;
  currency: string;
}

function Feedback({ state }: { state: IncomeActionState }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/**
 * "Catat Pendapatan" (decision 350, OWNER 8 October 2026): income that has no invoice, in plain fields and no
 * debit or credit. Every pick-or-type field works like the customer field on an invoice: the income type is a
 * revenue category (type to find it, or "+ Tambah ... baru" without leaving the form), "Dari siapa" is a customer
 * (the same quick-add panel), and the reference and the note offer what was typed on earlier entries. Below the
 * fields a plain-words preview says what will happen to the balance and to the tax base before anything is saved.
 */
export function IncomeForm({
  entity,
  today,
  categories,
  accounts,
  customers,
  referenceSuggestions,
  noteSuggestions,
}: {
  entity: string | undefined;
  today: string;
  categories: readonly IncomeCategoryChoice[];
  accounts: readonly IncomeAccountChoice[];
  customers: readonly { id: string; display_name: string }[];
  referenceSuggestions: readonly string[];
  noteSuggestions: readonly string[];
}) {
  const [state, action, pending] = useActionState(recordIncomeAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  const [categoryList, setCategoryList] = useState<IncomeCategoryChoice[]>([...categories]);
  const [categoryId, setCategoryId] = useState("");
  const [addingCategory, setAddingCategory] = useState(false);
  const [newCategoryName, setNewCategoryName] = useState("");
  const [customerList, setCustomerList] = useState([...customers]);
  const [customerId, setCustomerId] = useState("");
  const [addingCustomer, setAddingCustomer] = useState(false);
  const [newCustomerName, setNewCustomerName] = useState("");
  const [amount, setAmount] = useState("");
  const [accountId, setAccountId] = useState("");

  const category = categoryList.find((c) => c.id === categoryId);
  const account = accounts.find((a) => a.id === accountId);
  const amountNumber = Number(amount);
  const showPreview = category !== undefined && account !== undefined && amountNumber > 0;

  return (
    <>
      <form {...actionForm} className="record-form record-form-wide">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <label>
          Tanggal Uang Diterima
          <input type="date" name="entry_date" required max={today} defaultValue={today} />
        </label>
        <ContactPicker
          label="Jenis Pendapatan"
          name="category_id"
          noun="jenis pendapatan"
          contacts={categoryList.map((c) => ({ id: c.id, display_name: c.name }))}
          value={categoryId}
          onChange={setCategoryId}
          onAddNew={(typedName) => {
            setNewCategoryName(typedName);
            setAddingCategory(true);
          }}
        />
        {category ? <p className="hint">{incomeTaxNote(category.inTurnover)}</p> : null}
        <label>
          Jumlah
          <MoneyInput
            name="amount"
            required
            placeholder="mis. 2.500.000"
            value={amount}
            onValueChange={setAmount}
          />
        </label>
        <label>
          Diterima di Rekening
          <select
            name="account_id"
            required
            value={accountId}
            onChange={(event) => setAccountId(event.target.value)}
          >
            <option value="" disabled>
              Pilih rekening kas/bank
            </option>
            {accounts.map((a) => (
              <option key={a.id} value={a.id}>
                {a.label}
              </option>
            ))}
          </select>
        </label>
        <ContactPicker
          label="Dari Siapa (opsional)"
          name="contact_id"
          noun="pelanggan"
          contacts={customerList}
          value={customerId}
          optional
          onChange={setCustomerId}
          onAddNew={(typedName) => {
            setNewCustomerName(typedName);
            setAddingCustomer(true);
          }}
        />
        <SuggestTextInput
          label="Nomor Bukti / Referensi (opsional)"
          name="reference"
          noun="referensi"
          suggestions={referenceSuggestions}
          maxLength={200}
          placeholder="mis. Transfer BCA 12 Okt"
        />
        <SuggestTextInput
          label="Keterangan (opsional)"
          name="note"
          noun="keterangan"
          suggestions={noteSuggestions}
          maxLength={200}
          placeholder="mis. Pembayaran kursus tunai"
        />
        {showPreview ? (
          <div className="hint" role="status">
            <p>
              Saldo <strong>{account.name}</strong> bertambah{" "}
              <strong>{formatMoney(amount, account.currency)}</strong>.
            </p>
            <p>
              Pendapatan <strong>{category.accountName ?? category.name}</strong> bertambah{" "}
              <strong>{formatMoney(amount, account.currency)}</strong>.
            </p>
          </div>
        ) : null}
        <Feedback state={state} />
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Catat Pendapatan"}
        </button>
      </form>
      {/* Outside the form: a form inside a form is invalid HTML (see InvoiceForm). */}
      <QuickAddCategoryDrawer
        key={`cat-${newCategoryName}`}
        kind="revenue"
        entity={entity}
        initialName={newCategoryName}
        extraHint="Jenis baru dihitung sebagai pendapatan usaha (ikut dasar PPh Final 0,5%). Untuk pendapatan di luar usaha seperti bunga atau dividen, pilih jenis yang sudah ada di daftar."
        open={addingCategory}
        onClose={() => setAddingCategory(false)}
        onCreated={(created) => {
          // A new category posts to the default operating-revenue account until it is mapped on the Kategori screen.
          setCategoryList((list) => [
            ...list,
            { id: created.id, name: created.name, accountName: null, inTurnover: true },
          ]);
          setCategoryId(created.id);
          setAddingCategory(false);
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

/** Cancel an entry: one button and a reason; the system posts the reversal itself (no editing of a recorded entry). */
export function ReverseIncomeForm({ entryId, today }: { entryId: string; today: string }) {
  const [state, action, pending] = useActionState(reverseIncomeAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        Salah catat? Batalkan
      </button>
    );
  }
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entry_id" value={entryId} />
      <input type="hidden" name="date" value={today} />
      <label>
        Alasan (minimal 5 karakter)
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <p className="hint">
        Saldo rekening dan laporan kembali seperti sebelum dicatat. Catatan ini tetap tersimpan
        sebagai riwayat.
      </p>
      <Feedback state={state} />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Membatalkan…" : "Ya, Batalkan"}
      </button>
    </form>
  );
}
