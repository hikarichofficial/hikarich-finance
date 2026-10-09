"use client";

import { useEffect, useRef, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { useActionState } from "@/features/feedback/useActionState";
import { Drawer } from "@/features/shell/Drawer";
import { quickCreateCategoryAction } from "./categoryActions";
import { idleQuickCreateCategoryState } from "./categoryActionsState";
import { CATEGORY_KIND_LABELS } from "./kindLabels";
import { PersonalRoleSelect } from "./CategoryForms";

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
  personal = false,
  open,
  onClose,
  onCreated,
}: {
  kind: "revenue" | "expense" | "asset";
  entity: string | undefined;
  initialName?: string;
  /** A sentence about what the new category means in the form it is added from (e.g. its tax treatment). */
  extraHint?: string;
  /** A Personal book: also ask which part of the personal tax the new category belongs to (decision 365). */
  personal?: boolean;
  open: boolean;
  onClose: () => void;
  onCreated: (category: {
    id: string;
    name: string;
    kind: string;
    personal_tax_role?: string | null;
  }) => void;
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

  // The drawer is opened from inside another form (the expense / invoice / income form). It is drawn on the
  // page body, outside that form, and its own submit never reaches the outer form: an outer form that handles
  // `onSubmit` itself (usePreservingForm) used to take the click, so "Simpan & Gunakan" did nothing.
  const mounted = useSyncExternalStore(
    () => () => {},
    () => true,
    () => false,
  );
  if (!mounted) return null;

  const kindLabel = (CATEGORY_KIND_LABELS as Record<string, string>)[kind] ?? kind;

  return createPortal(
    <Drawer open={open} onClose={onClose} title="Tambah Kategori Baru">
      <form
        ref={formRef}
        action={formAction}
        className="record-form"
        onSubmit={(event) => event.stopPropagation()}
      >
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
        {personal ? <PersonalRoleSelect kind={kind} label="Pajak Pribadi" /> : null}
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
    </Drawer>,
    document.body,
  );
}
