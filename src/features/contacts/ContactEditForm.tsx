"use client";

import { useActionState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import type { ContactRow } from "@/schemas/contacts";
import { updateContactAction } from "./contactActions";
import { idleContactActionState } from "./contactActionsState";

/** Edit Customer / Edit Vendor (finding #90). The tax identifier is not editable here (it is stored
 * encrypted-at-rest and revealed only on demand); the contact's role can only be widened to "both". */
export function ContactEditForm({
  contact,
  contactRole,
  entity,
}: {
  contact: ContactRow;
  contactRole: "customer" | "vendor";
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(updateContactAction, idleContactActionState);
  const actionForm = usePreservingForm(action, state);
  const otherRole = contactRole === "customer" ? "vendor" : "pelanggan";

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="role" value={contactRole} />
      <input type="hidden" name="contact_id" value={contact.id} />
      <label>
        Nama
        <input name="display_name" required maxLength={200} defaultValue={contact.display_name} />
      </label>
      <label>
        Nama Resmi / Badan (opsional)
        <input name="legal_name" maxLength={200} defaultValue={contact.legal_name ?? ""} />
      </label>
      <label>
        Email (opsional)
        <input type="email" name="email" maxLength={200} defaultValue={contact.email ?? ""} />
      </label>
      <label>
        Telepon (opsional)
        <input name="phone" maxLength={40} defaultValue={contact.phone ?? ""} />
      </label>
      <label>
        Alamat (opsional)
        <input name="address_line" maxLength={300} defaultValue={contact.address_line ?? ""} />
      </label>
      <label>
        Kota (opsional)
        <input name="city" maxLength={100} defaultValue={contact.city ?? ""} />
      </label>
      <label>
        Kode Negara (2 huruf)
        <input name="country_code" maxLength={2} defaultValue={contact.country_code ?? ""} />
      </label>
      <label>
        Catatan (opsional)
        <textarea name="notes" maxLength={1000} defaultValue={contact.notes ?? ""} />
      </label>
      {contact.kind !== "both" ? (
        <label className="checkbox-field">
          <input type="checkbox" name="also_other_role" /> Kontak ini juga {otherRole}
        </label>
      ) : null}
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Perubahan"}
      </button>
    </form>
  );
}
