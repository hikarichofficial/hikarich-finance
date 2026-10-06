"use client";

import { CATEGORY_KIND_LABELS } from "./kindLabels";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import { VAT_TREATMENT_LABELS, WHT_OBJECT_LABELS } from "@/domain/tax/tax";
import {
  createCategoryAction,
  setCategoryAccountAction,
  updateCategoryAction,
  type CategoryActionState,
} from "./categoryActions";

const IDLE: CategoryActionState = { status: "idle" };

function TaxKeyOptions() {
  return (
    <>
      <option value="">Otomatis dari profil pajak (disarankan)</option>
      <optgroup label="Penjualan (PPN)">
        {Object.entries(VAT_TREATMENT_LABELS).map(([value, label]) => (
          <option key={value} value={value}>
            {label}
          </option>
        ))}
      </optgroup>
      <optgroup label="Pembelian (potongan PPh)">
        {Object.entries(WHT_OBJECT_LABELS).map(([value, label]) => (
          <option key={value} value={value}>
            {label}
          </option>
        ))}
      </optgroup>
    </>
  );
}

function Feedback({ state }: { state: CategoryActionState }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/** Add a category (decision 262). The tax mapping is what a line uses when it names no tax fact itself. */
export function CategoryCreateForm({ entity }: { entity: string | undefined }) {
  const [state, action, pending] = useActionState(createCategoryAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Nama Kategori
        <input name="name" required maxLength={120} placeholder="mis. Sewa Kantor" />
      </label>
      <label>
        Jenis
        <select name="kind" defaultValue="expense">
          {Object.entries(CATEGORY_KIND_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Perlakuan Pajak (opsional)
        <select name="tax_category_key" defaultValue="">
          <TaxKeyOptions />
        </select>
      </label>
      <p className="hint">
        Pajak tetap dihitung otomatis dari profil pajak entitas, jadi biarkan pilihan pertama
        &quot;Otomatis&quot;. Pilih perlakuan lain hanya jika kategori ini SELALU punya perlakuan
        pajak tertentu; pilihan ini hanya dipakai bila baris dokumen tidak menyebut pajaknya
        sendiri.
      </p>
      <Feedback state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Tambah Kategori"}
      </button>
    </form>
  );
}

/** Change a category's tax mapping or switch it off (decision 262). */
export function CategoryRowForm({
  entity,
  id,
  taxKey,
  isActive,
}: {
  entity: string | undefined;
  id: string;
  taxKey: string | null;
  isActive: boolean;
}) {
  const [state, action, pending] = useActionState(updateCategoryAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="id" value={id} />
      <select name="tax_category_key" defaultValue={taxKey ?? ""} aria-label="Perlakuan pajak">
        <TaxKeyOptions />
      </select>
      <label className="checkbox-field">
        <input type="checkbox" name="is_active" defaultChecked={isActive} /> Aktif
      </label>
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "…" : "Simpan"}
      </button>
      <Feedback state={state} />
    </form>
  );
}

/** Choose the ledger account a revenue or expense category posts to, from a date on (decision 265).
 * Documents already posted keep the account they had. */
export function CategoryAccountForm({
  entity,
  categoryId,
  accounts,
  currentAccountId,
  today,
}: {
  entity: string | undefined;
  categoryId: string;
  accounts: readonly { id: string; label: string }[];
  currentAccountId: string | null;
  today: string;
}) {
  const [state, action, pending] = useActionState(setCategoryAccountAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="category_id" value={categoryId} />
      <select name="account_id" defaultValue={currentAccountId ?? ""} aria-label="Akun">
        <option value="">Akun bawaan</option>
        {accounts.map((account) => (
          <option key={account.id} value={account.id}>
            {account.label}
          </option>
        ))}
      </select>
      <input
        type="date"
        name="effective_from"
        required
        defaultValue={today}
        aria-label="Berlaku sejak"
      />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "…" : "Simpan"}
      </button>
      <Feedback state={state} />
    </form>
  );
}
