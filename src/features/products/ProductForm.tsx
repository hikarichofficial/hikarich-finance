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
import { ContactPicker } from "@/features/contacts/ContactPicker";
import { QuickAddCategoryDrawer } from "@/features/categories/QuickAddCategoryDrawer";
import { QuickAddSkuMasterDrawer } from "./QuickAddSkuMasterDrawer";

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
  canAddMasters = false,
  canAddCategories = false,
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
  /** `products.sku_settings`: may add a brand or product type from here (decision 351). */
  canAddMasters?: boolean;
  /** `categories.manage`: may add a revenue category from here. */
  canAddCategories?: boolean;
}) {
  const [brandId, setBrandId] = useState("");
  const [typeId, setTypeId] = useState("");
  // Local copies so what was just added is picked straight away, without reloading the form.
  const [brandList, setBrandList] = useState<SkuChoice[]>([...brands]);
  const [typeList, setTypeList] = useState<SkuChoice[]>([...types]);
  const [categoryList, setCategoryList] = useState<{ id: string; display_name: string }[]>(
    categories.map((c) => ({ id: c.id, display_name: c.name })),
  );
  const [categoryId, setCategoryId] = useState(product?.default_category_id ?? "");
  const [adding, setAdding] = useState<{
    what: "brand" | "type" | "category";
    name: string;
  } | null>(null);
  const [manual, setManual] = useState(false);
  const [state, action, pending] = useActionState(saveProductAction, idleProductFormState);
  const actionForm = usePreservingForm(action, state);
  const price = product?.default_unit_price;

  return (
    <>
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
              SKU tidak diubah dari formulir ini. Owner dapat mengubahnya dari halaman detail
              produk; dokumen lama tetap memakai SKU sebelumnya.
            </p>
          </div>
        ) : (
          <>
            {autoGenerate ? (
              <>
                <ContactPicker
                  label="Brand"
                  name="brand_id"
                  noun="brand"
                  contacts={brandList.map((b) => ({
                    id: b.id,
                    display_name: `${b.name} (${b.code})`,
                  }))}
                  value={brandId}
                  optional={manual}
                  onChange={setBrandId}
                  onAddNew={
                    canAddMasters
                      ? (typedName) => setAdding({ what: "brand", name: typedName })
                      : undefined
                  }
                />
                <ContactPicker
                  label="Jenis Produk"
                  name="product_type_id"
                  noun="jenis produk"
                  contacts={typeList.map((t) => ({
                    id: t.id,
                    display_name: `${t.name} (${t.code})`,
                  }))}
                  value={typeId}
                  optional={manual}
                  onChange={setTypeId}
                  onAddNew={
                    canAddMasters
                      ? (typedName) => setAdding({ what: "type", name: typedName })
                      : undefined
                  }
                />
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
        <ContactPicker
          label="Kategori Pendapatan Bawaan (opsional)"
          name="default_category_id"
          noun="kategori pendapatan"
          contacts={categoryList}
          value={categoryId}
          optional
          onChange={setCategoryId}
          onAddNew={
            canAddCategories
              ? (typedName) => setAdding({ what: "category", name: typedName })
              : undefined
          }
        />
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
      {/* Outside the form: a form inside a form is invalid HTML (see InvoiceForm). */}
      {adding && adding.what !== "category" ? (
        <QuickAddSkuMasterDrawer
          key={`${adding.what}-${adding.name}`}
          kind={adding.what}
          entity={entity}
          initialName={adding.name}
          open
          onClose={() => setAdding(null)}
          onCreated={(item) => {
            if (adding.what === "brand") {
              setBrandList((list) => [...list, item]);
              setBrandId(item.id);
            } else {
              setTypeList((list) => [...list, item]);
              setTypeId(item.id);
            }
            setAdding(null);
          }}
        />
      ) : null}
      {adding && adding.what === "category" ? (
        <QuickAddCategoryDrawer
          key={`category-${adding.name}`}
          kind="revenue"
          entity={entity}
          initialName={adding.name}
          open
          onClose={() => setAdding(null)}
          onCreated={(created) => {
            setCategoryList((list) => [...list, { id: created.id, display_name: created.name }]);
            setCategoryId(created.id);
            setAdding(null);
          }}
        />
      ) : null}
    </>
  );
}
