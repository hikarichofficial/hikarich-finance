"use client";

import { useActionState, useEffect, useRef } from "react";
import { Drawer } from "@/features/shell/Drawer";
import {
  idleQuickCreateContactState,
  quickCreateCustomerAction,
  quickCreateVendorAction,
} from "./contactActions";

/**
 * Add-a-customer/vendor-on-the-spot Drawer (owner, 4 October 2026: a form that needs a contact -- Buat
 * Invoice today, a Bill tomorrow -- should offer "add new" or "search and pick an existing one" right
 * there, not send the person away to the Contacts screen and back). Only the fields a quick add really
 * needs; the full Add Customer/Vendor screen (linked below the form) still covers everything else
 * (address, tax ID, notes, "also a vendor") for when the person wants to fill that in up front instead.
 */
export function QuickAddContactDrawer({
  contactKind,
  entity,
  open,
  onClose,
  onCreated,
}: {
  contactKind: "customer" | "vendor";
  entity: string | undefined;
  open: boolean;
  onClose: () => void;
  onCreated: (contact: { id: string; display_name: string }) => void;
}) {
  const action = contactKind === "vendor" ? quickCreateVendorAction : quickCreateCustomerAction;
  const [state, formAction, pending] = useActionState(action, idleQuickCreateContactState);
  const formRef = useRef<HTMLFormElement>(null);
  // Guards against re-firing onCreated if the Drawer re-renders without a fresh submit (e.g. the parent
  // re-opening it) while `state` still holds the previous success.
  const handledContactId = useRef<string | null>(null);

  useEffect(() => {
    if (state.status === "ok" && state.contact && handledContactId.current !== state.contact.id) {
      handledContactId.current = state.contact.id;
      onCreated(state.contact);
      formRef.current?.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onCreated/onClose are re-created each render
  }, [state]);

  const fullFormHref = entity
    ? `${contactKind === "vendor" ? "/purchases/vendors/new" : "/sales/customers/new"}?entity=${encodeURIComponent(entity)}`
    : contactKind === "vendor"
      ? "/purchases/vendors/new"
      : "/sales/customers/new";

  return (
    <Drawer
      open={open}
      onClose={onClose}
      title={contactKind === "vendor" ? "Tambah Vendor Baru" : "Tambah Pelanggan Baru"}
    >
      <form ref={formRef} action={formAction} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <label>
          Nama
          <input name="display_name" required maxLength={200} autoComplete="off" />
        </label>
        <label>
          Email (opsional)
          <input type="email" name="email" maxLength={200} autoComplete="off" />
        </label>
        <label>
          Telepon (opsional)
          <input name="phone" maxLength={50} autoComplete="off" />
        </label>
        <p className="hint">
          Isian lain (alamat, NPWP, catatan) bisa dilengkapi nanti di halaman{" "}
          <a href={fullFormHref} target="_blank" rel="noreferrer">
            {contactKind === "vendor" ? "Tambah Vendor" : "Tambah Pelanggan"}
          </a>
          .
        </p>
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
