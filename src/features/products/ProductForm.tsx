"use client";

import { useActionState } from "react";
import type { CategoryRow } from "@/schemas/categories";
import type { ProductRow } from "@/schemas/products";
import { idleProductFormState, saveProductAction } from "./actions";

/** Product create/edit form (decision 245). The same form serves both: a `product_id` makes it an edit. */
export function ProductForm({
  product,
  categories,
  baseCurrency,
  entity,
}: {
  product: ProductRow | null;
  categories: readonly CategoryRow[];
  baseCurrency: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(saveProductAction, idleProductFormState);
  const price = product?.default_unit_price;

  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="product_id" value={product?.id ?? ""} />
      <input type="hidden" name="version" value={product?.version ?? ""} />

      <label>
        Jenis
        <select name="kind" defaultValue={product?.kind ?? "product"}>
          <option value="product">Produk</option>
          <option value="service">Jasa</option>
        </select>
      </label>
      <label>
        Nama
        <input name="name" required maxLength={200} defaultValue={product?.name ?? ""} />
      </label>
      <label>
        SKU / Kode (opsional)
        <input name="sku" maxLength={64} defaultValue={product?.sku ?? ""} />
      </label>
      <label>
        Satuan
        <input name="unit" required maxLength={32} defaultValue={product?.unit ?? "unit"} />
      </label>
      <label>
        Harga Satuan Bawaan (opsional)
        <input
          name="default_unit_price"
          inputMode="decimal"
          placeholder="mis. 150000"
          defaultValue={price === null || price === undefined ? "" : String(price)}
        />
      </label>
      <label>
        Mata Uang Harga (opsional)
        <input
          name="default_currency"
          maxLength={3}
          placeholder={baseCurrency}
          defaultValue={product?.default_currency ?? ""}
        />
      </label>
      <label>
        Kategori Pendapatan Bawaan (opsional)
        <select name="default_category_id" defaultValue={product?.default_category_id ?? ""}>
          <option value="">— Tidak ada —</option>
          {categories.map((category) => (
            <option key={category.id} value={category.id}>
              {category.name}
            </option>
          ))}
        </select>
      </label>
      <label>
        Deskripsi (opsional)
        <textarea name="description" maxLength={2000} defaultValue={product?.description ?? ""} />
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="is_active" defaultChecked={product?.is_active ?? true} />
        Aktif (dapat dipilih saat membuat faktur)
      </label>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : product ? "Simpan Perubahan" : "Simpan Produk"}
      </button>
    </form>
  );
}
