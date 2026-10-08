"use client";

import { useEffect, useRef } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { Drawer } from "@/features/shell/Drawer";
import { quickCreateCategoryAction } from "./categoryActions";
import { idleQuickCreateCategoryState } from "./categoryActionsState";
import { CATEGORY_KIND_LABELS } from "./kindLabels";

/**
 * Add-a-category-on-the-spot Drawer (OWNER, 7 October 2026: a category field should work like the customer
 * field -- type, pick, or add a new one right there). Only the name is asked: the kind follows the line it
 * is added for. A category added here posts to the default account of its kind until it is mapped to a
 * specific ledger account on the Kategori screen, which the hint says.
 */
export function QuickAddCategoryDrawer({
  kind,
  entity,
  initialName = "",
  extraHint,
  open,
  onClose,
  onCreated,
}: {
  kind: "revenue" | "expense" | "asset";
  entity: string | undefined;
  initialName?: string;
  /** A sentence about what the new category means in the form it is added from (e.g. its tax treatment). */
  extraHint?: string;
  open: boolean;
  onClose: () => void;
  onCreated: (category: { id: string; name: string; kind: string }) => void;
}) {
  const [state, formAction, pending] = useActionState(
    quickCreateCategoryAction,
    idleQuickCreateCategoryState,
  );
  const formRef = useRef<HTMLFormElement>(null);
  const handledId = useRef<string | null>(null);

  useEffect(() => {
    if (state.status === "ok" && state.category && handledId.current !== state.category.id) {
      handledId.current = state.category.id;
      onCreated(state.category);
      formRef.current?.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onCreated is re-created each render
  }, [state]);

  const kindLabel = (CATEGORY_KIND_LABELS as Record<string, string>)[kind] ?? kind;

  return (
    <Drawer open={open} onClose={onClose} title="Tambah Kategori Baru">
      <form ref={formRef} action={formAction} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="kind" value={kind} />
        <label>
          Nama Kategori
          <input
            name="name"
            required
            maxLength={120}
            autoComplete="off"
            defaultValue={initialName}
          />
        </label>
        <p className="hint">
          Jenis: {kindLabel}. Kategori baru dicatat ke akun bawaan jenis ini. Untuk memetakannya ke
          akun tertentu, buka Akuntansi → Kategori.
        </p>
        {extraHint ? <p className="hint">{extraHint}</p> : null}
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
