"use client";

import { useState } from "react";
import { CATEGORY_KIND_LABELS } from "./kindLabels";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import {
  PERSONAL_ROLE_LABELS,
  personalRolesForKind,
  untaggedLabel,
} from "@/domain/tax/personalTaxRoles";
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
      <optgroup label="Pembelian (PPh)">
        {Object.entries(WHT_OBJECT_LABELS).map(([value, label]) => (
          <option key={value} value={value}>
            {label}
          </option>
        ))}
      </optgroup>
    </>
  );
}

/** The Personal-book tag of a category (decision 365): which part of the personal tax it belongs to. */
export function PersonalRoleSelect({
  kind,
  defaultValue,
  label,
}: {
  kind: string;
  defaultValue?: string | null;
  /** When given, the select is wrapped in a labelled field; otherwise it is a bare select for a table row. */
  label?: string;
}) {
  const roles = personalRolesForKind(kind);
  if (roles.length === 0) return null;
  const select = (
    <select name="personal_tax_role" defaultValue={defaultValue ?? ""} aria-label="Pajak Pribadi">
      <option value="">{untaggedLabel(kind)}</option>
      {roles.map((role) => (
        <option key={role} value={role}>
          {PERSONAL_ROLE_LABELS[role]}
        </option>
      ))}
    </select>
  );
  return label ? (
    <label>
      {label}
      {select}
    </label>
  ) : (
    select
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
export function CategoryCreateForm({
  entity,
  personal = false,
}: {
  entity: string | undefined;
  personal?: boolean;
}) {
  const [state, action, pending] = useActionState(createCategoryAction, IDLE);
  const [kind, setKind] = useState("expense");
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
        <select name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
          {Object.entries(CATEGORY_KIND_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      {personal ? (
        personalRolesForKind(kind).length > 0 ? (
          <PersonalRoleSelect key={kind} kind={kind} label="Pajak Pribadi" />
        ) : null
      ) : (
        <>
          <label>
            Perlakuan Pajak (opsional)
            <select name="tax_category_key" defaultValue="">
              <TaxKeyOptions />
            </select>
          </label>
          <p className="hint">
            Pajak tetap dihitung otomatis dari profil pajak entitas, jadi biarkan pilihan pertama
            &quot;Otomatis&quot;. Pilih perlakuan lain hanya jika kategori ini SELALU punya
            perlakuan pajak tertentu; pilihan ini hanya dipakai bila baris dokumen tidak menyebut
            pajaknya sendiri.
          </p>
        </>
      )}
      {personal ? (
        <p className="hint">
          Tanda ini menentukan apakah kategori masuk hitungan Pajak Pribadi. Tanpa tanda, berarti
          pribadi dan tidak dihitung.
        </p>
      ) : null}
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
  personalKind,
  personalRole,
}: {
  entity: string | undefined;
  id: string;
  taxKey: string | null;
  isActive: boolean;
  /** Set for a Personal book: the category kind, so the tag choices fit it. */
  personalKind?: string;
  personalRole?: string | null;
}) {
  const [state, action, pending] = useActionState(updateCategoryAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="id" value={id} />
      {personalKind !== undefined ? (
        <>
          <input type="hidden" name="kind" value={personalKind} />
          <PersonalRoleSelect kind={personalKind} defaultValue={personalRole} />
        </>
      ) : (
        <select name="tax_category_key" defaultValue={taxKey ?? ""} aria-label="Perlakuan pajak">
          <TaxKeyOptions />
        </select>
      )}
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
