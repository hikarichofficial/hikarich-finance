"use client";

import { useEffect, useRef, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { Drawer } from "@/features/shell/Drawer";
import { suggestSkuCode, VARIANT_TYPE_LABELS } from "@/domain/products/sku";
import type { SkuMasterKind } from "@/schemas/sku";
import { quickCreateSkuMasterAction } from "./skuActions";
import { idleQuickCreateSkuMasterState } from "./skuActionsState";

const COPY: Readonly<Record<SkuMasterKind, { title: string; one: string; hint: string }>> = {
  brand: {
    title: "Tambah Brand Baru",
    one: "brand",
    hint: "Kode brand menjadi bagian pertama SKU, mis. Kamar EA = KEA.",
  },
  type: {
    title: "Tambah Jenis Produk Baru",
    one: "jenis produk",
    hint: "Kode jenis produk menjadi bagian kedua SKU, mis. Expert Advisor = EA.",
  },
  variant: {
    title: "Tambah Variant Baru",
    one: "variant",
    hint: "Kode variant menjadi bagian terakhir SKU, mis. 1B untuk 1 bulan.",
  },
};

/**
 * Add-a-brand / product type / variant-on-the-spot Drawer (OWNER, 8 October 2026: these fields had no way to add
 * a new entry; they must work like the customer field). Name and code only (the code is suggested from the name
 * and can be changed); everything else (description, order, switching off) stays on Administrasi > SKU. A variant
 * also asks its kind and, optionally, its validity in days.
 */
export function QuickAddSkuMasterDrawer({
  kind,
  entity,
  initialName = "",
  open,
  onClose,
  onCreated,
}: {
  kind: SkuMasterKind;
  entity: string | undefined;
  initialName?: string;
  open: boolean;
  onClose: () => void;
  onCreated: (item: { id: string; name: string; code: string }) => void;
}) {
  const copy = COPY[kind];
  const [state, formAction, pending] = useActionState(
    quickCreateSkuMasterAction,
    idleQuickCreateSkuMasterState,
  );
  const formRef = useRef<HTMLFormElement>(null);
  const handledId = useRef<string | null>(null);
  const [name, setName] = useState(initialName);
  const [code, setCode] = useState(suggestSkuCode(initialName));
  // Until the person types their own code, it follows the name.
  const [codeEdited, setCodeEdited] = useState(false);

  useEffect(() => {
    if (state.status === "ok" && state.item && handledId.current !== state.item.id) {
      handledId.current = state.item.id;
      onCreated(state.item);
      formRef.current?.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onCreated is re-created each render
  }, [state]);

  return (
    <Drawer open={open} onClose={onClose} title={copy.title}>
      <form ref={formRef} action={formAction} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="kind" value={kind} />
        <label>
          Nama
          <input
            name="name"
            required
            maxLength={120}
            autoComplete="off"
            value={name}
            onChange={(event) => {
              setName(event.target.value);
              if (!codeEdited) setCode(suggestSkuCode(event.target.value));
            }}
          />
        </label>
        <label>
          Kode
          <input
            name="code"
            required
            maxLength={12}
            pattern="[A-Za-z0-9]{1,12}"
            autoComplete="off"
            style={{ textTransform: "uppercase" }}
            value={code}
            onChange={(event) => {
              setCode(event.target.value.toUpperCase());
              setCodeEdited(true);
            }}
          />
          <span className="hint">
            {copy.hint} Huruf besar dan angka, maksimal 12, dan tidak boleh sama dengan yang sudah
            ada.
          </span>
        </label>
        {kind === "variant" ? (
          <>
            <label>
              Jenis variant
              <select name="variant_type" defaultValue="validity">
                {Object.entries(VARIANT_TYPE_LABELS).map(([value, label]) => (
                  <option key={value} value={value}>
                    {label}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Masa berlaku (hari, opsional)
              <input name="validity_days" type="number" min={1} placeholder="mis. 30" />
            </label>
          </>
        ) : null}
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}
        <div>
          <button type="submit" className="btn-primary" disabled={pending}>
            {pending ? "Menyimpan…" : "Simpan & Gunakan"}
          </button>
        </div>
      </form>
    </Drawer>
  );
}
