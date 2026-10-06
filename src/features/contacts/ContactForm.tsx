"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import { createContactAction } from "./contactActions";
import { idleContactActionState } from "./contactActionsState";

/**
 * Add Customer / Add Vendor (Step 09 §11/§12, decision 258) through `create_contact`. The database refuses
 * an exact duplicate and asks for confirmation on a similar name; the checkbox is that confirmation.
 */
export function ContactForm({
  contactRole,
  entity,
}: {
  contactRole: "customer" | "vendor";
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(createContactAction, idleContactActionState);
  const actionForm = usePreservingForm(action, state);
  const otherRole = contactRole === "customer" ? "vendor" : "pelanggan";

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="role" value={contactRole} />
      <label>
        Nama
        <input name="display_name" required maxLength={200} />
      </label>
      <label>
        Nama Resmi / Badan (opsional)
        <input name="legal_name" maxLength={200} placeholder="mis. PT Contoh Abadi" />
      </label>
      <label>
        Email (opsional)
        <input type="email" name="email" maxLength={200} />
      </label>
      <label>
        Telepon (opsional)
        <input name="phone" maxLength={40} />
      </label>
      <label>
        NPWP / NIK (opsional)
        <input name="tax_identifier" maxLength={40} />
      </label>
      <label>
        Alamat (opsional)
        <input name="address_line" maxLength={300} />
      </label>
      <label>
        Kota (opsional)
        <input name="city" maxLength={100} />
      </label>
      <label>
        Kode Negara (2 huruf)
        <input name="country_code" maxLength={2} defaultValue="ID" />
      </label>
      <label>
        Catatan (opsional)
        <textarea name="notes" maxLength={1000} />
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="also_other_role" /> Kontak ini juga {otherRole}
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="allow_similar_name" /> Tetap simpan walau ada nama yang mirip
        (ini pihak yang berbeda)
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan"}
      </button>
    </form>
  );
}
