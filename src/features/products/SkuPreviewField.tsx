"use client";

import { useEffect, useState } from "react";
import { previewSkuAction } from "./skuActions";

/** Live SKU preview (decision 324): asks the database what the SKU would be for the chosen brand, type and variant.
 * Read only; the real number is taken only when the product is saved. */
export function SkuPreviewField({
  entity,
  brandId,
  typeId,
  variantId,
  parentId,
  label = "Pratinjau SKU",
}: {
  entity: string | undefined;
  brandId: string;
  typeId: string;
  variantId?: string;
  parentId?: string;
  label?: string;
}) {
  const [text, setText] = useState<string>("—");
  const [note, setNote] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const ready = parentId ? Boolean(variantId) : Boolean(brandId && typeId);
    if (!ready) {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setText("—");
      setNote("Pilih Brand dan Jenis Produk untuk melihat SKU.");
      return;
    }
    const timer = setTimeout(() => {
      void previewSkuAction({ entity: entity ?? "", brandId, typeId, variantId, parentId }).then(
        (result) => {
          if (cancelled) return;
          if (result.error) {
            setText("—");
            setNote("SKU belum dapat dibuat dari pilihan ini.");
          } else {
            setText(result.sku ?? "—");
            setNote(
              result.auto === false
                ? "SKU otomatis sedang mati; SKU harus diisi manual oleh Owner."
                : "Nomor final diberikan saat disimpan.",
            );
          }
        },
      );
    }, 200);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [entity, brandId, typeId, variantId, parentId]);

  return (
    <div className="sku-preview-field">
      <span className="hint">{label}</span>
      <p className="sku-preview" aria-live="polite">
        {text}
      </p>
      {note ? <p className="hint">{note}</p> : null}
    </div>
  );
}
