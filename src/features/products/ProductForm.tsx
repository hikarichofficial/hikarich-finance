"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import type { CategoryRow } from "@/schemas/categories";
import type { ProductRow } from "@/schemas/products";
import { saveProductAction } from "./actions";
import { idleProductFormState } from "./actionsState";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { useState } from "react";
import { SkuPreviewField } from "./SkuPreviewField";

export interface SkuChoice {
  id: string;
  name: string;
  code: string;
}

/** Product create/edit form (decision 245). The same form serves both: a `product_id` makes it an edit. */
export function ProductForm({
  product,
  categories,
  baseCurrency,
  entity,
  brands = [],
  types = [],
  autoGenerate = false,
  canOverride = false,
}: {
  product: ProductRow | null;
  categories: readonly CategoryRow[];
  baseCurrency: string;
  entity: string | undefined;
  /** Brands and product types to pick from (live ones only) and whether SKUs are generated (decision 324). */
  brands?: readonly SkuChoice[];
  types?: readonly SkuChoice[];
  autoGenerate?: boolean;
  /** Owner / `products.sku_override`: may type a SKU by hand when creating. */
  canOverride?: boolean;
}) {
  const [brandId, setBrandId] = useState("");
  const [typeId, setTypeId] = useState("");
  const [manual, setManual] = useState(false);
  const [state, action, pending] = useActionState(saveProductAction, idleProductFormState);
  const actionForm = usePreservingForm(action, state);
  const price = product?.default_unit_price;

  return (
    <form {...actionForm} className="record-form">
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
      {product ? (
        <div className="sku-preview-field">
          <span className="hint">SKU</span>
          <p className="sku-preview">{product.sku ?? "—"}</p>
          <p className="hint">
            SKU tidak diubah dari formulir ini. Owner dapat mengubahnya dari halaman detail produk;
            dokumen lama tetap memakai SKU sebelumnya.
          </p>
        </div>
      ) : (
        <>
          {autoGenerate ? (
            <>
              <label>
                Brand
                <select
                  name="brand_id"
                  value={brandId}
                  onChange={(event) => setBrandId(event.target.value)}
                  required={!manual}
                >
                  <option value="">— Pilih Brand —</option>
                  {brands.map((brand) => (
                    <option key={brand.id} value={brand.id}>
                      {brand.name} ({brand.code})
                    </option>
                  ))}
                </select>
              </label>
              <label>
                Jenis Produk
                <select
                  name="product_type_id"
                  value={typeId}
                  onChange={(event) => setTypeId(event.target.value)}
                  required={!manual}
                >
                  <option value="">— Pilih Jenis Produk —</option>
                  {types.map((type) => (
                    <option key={type.id} value={type.id}>
                      {type.name} ({type.code})
                    </option>
                  ))}
                </select>
              </label>
              {!manual ? (
                <SkuPreviewField entity={entity} brandId={brandId} typeId={typeId} />
              ) : null}
            </>
          ) : (
            <p className="hint">
              SKU otomatis sedang mati. Owner dapat mengisi SKU manual di bawah.
            </p>
          )}
          {canOverride ? (
            <>
              <label className="checkbox-field">
                <input
                  type="checkbox"
                  name="manual_sku"
                  checked={manual}
                  onChange={(event) => setManual(event.target.checked)}
                />
                Isi SKU secara manual (khusus Owner)
              </label>
              {manual ? (
                <label>
                  SKU manual
                  <input name="sku" maxLength={64} required />
                  <span className="hint">
                    SKU manual tidak mengikuti struktur otomatis, tetapi tetap harus unik.
                  </span>
                </label>
              ) : null}
            </>
          ) : null}
        </>
      )}
      <label>
        Satuan
        <input name="unit" required maxLength={32} defaultValue={product?.unit ?? "unit"} />
      </label>
      <label>
        Harga Satuan Bawaan (opsional)
        <MoneyInput
          name="default_unit_price"
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
        Aktif (dapat dipilih saat membuat invoice)
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
