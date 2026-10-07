"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { addVariantAction, setProductSkuAction } from "./skuActions";
import { idleSkuActionState } from "./skuActionsState";
import { SkuPreviewField } from "./SkuPreviewField";

/** Owner / `products.sku_override`: change this product's SKU by hand. Documents already issued keep the SKU they
 * carry; the change is recorded in the history with its reason (decision 324). */
export function ChangeSkuForm({
  entity,
  productId,
  currentSku,
  usedOnDocuments,
}: {
  entity: string | undefined;
  productId: string;
  currentSku: string | null;
  usedOnDocuments: boolean;
}) {
  const [state, run, pending] = useActionState(setProductSkuAction, idleSkuActionState);
  const form = usePreservingForm(run, state);
  return (
    <details className="account-edit">
      <summary className="btn-secondary">Ubah SKU (Owner)</summary>
      <form {...form} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="product_id" value={productId} />
        {usedOnDocuments ? (
          <p className="notice">
            SKU ini sudah pernah dipakai pada transaksi. Mengubah SKU master tidak akan mengubah
            catatan transaksi lama.
          </p>
        ) : null}
        <label>
          SKU baru
          <input name="sku" required maxLength={64} defaultValue={currentSku ?? ""} />
          <span className="hint">SKU manual tidak mengikuti struktur otomatis dan harus unik.</span>
        </label>
        <label>
          Alasan (opsional)
          <input name="reason" maxLength={200} />
        </label>
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan SKU"}
        </button>
      </form>
    </details>
  );
}

/** Adds a variant (own SKU, price and status) to a main product; the SKU is the product's SKU plus the variant code. */
export function AddVariantForm({
  entity,
  parentId,
  variants,
}: {
  entity: string | undefined;
  parentId: string;
  variants: readonly { id: string; name: string; code: string }[];
}) {
  const [state, run, pending] = useActionState(addVariantAction, idleSkuActionState);
  const form = usePreservingForm(run, state);
  const [variantId, setVariantId] = useState("");
  return (
    <form {...form} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="parent_id" value={parentId} />
      <label>
        Variant
        <select
          name="variant_id"
          required
          value={variantId}
          onChange={(event) => setVariantId(event.target.value)}
        >
          <option value="">— Pilih Variant —</option>
          {variants.map((variant) => (
            <option key={variant.id} value={variant.id}>
              {variant.name} ({variant.code})
            </option>
          ))}
        </select>
      </label>
      <SkuPreviewField
        entity={entity}
        brandId=""
        typeId=""
        variantId={variantId}
        parentId={parentId}
        label="SKU variant"
      />
      <label>
        Harga variant (opsional, bawaan: harga produk)
        <MoneyInput name="price" placeholder="mis. 150000" defaultValue="" />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Tambah Variant"}
      </button>
    </form>
  );
}
