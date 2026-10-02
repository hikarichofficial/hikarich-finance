"use client";

import { useActionState } from "react";
import { VAT_TREATMENT_LABELS, WHT_OBJECT_LABELS } from "@/domain/tax/tax";
import {
  createCategoryAction,
  updateCategoryAction,
  type CategoryActionState,
} from "./categoryActions";

const IDLE: CategoryActionState = { status: "idle" };

export const CATEGORY_KIND_LABELS: Readonly<Record<string, string>> = {
  revenue: "Pendapatan",
  expense: "Beban",
  asset: "Aset",
  liability: "Kewajiban",
  equity: "Modal",
  other: "Lainnya",
};

function TaxKeyOptions() {
  return (
    <>
      <option value="">Tanpa pemetaan pajak</option>
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
  return (
    <form action={action} className="record-form">
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
        Pemetaan Pajak Otomatis
        <select name="tax_category_key" defaultValue="">
          <TaxKeyOptions />
        </select>
      </label>
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
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="id" value={id} />
      <select name="tax_category_key" defaultValue={taxKey ?? ""} aria-label="Pemetaan pajak">
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
