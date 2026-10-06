"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { createEntityAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

/** Add an Entity (decision 276): a further business or household ledger. Only an OWNER sees this form; the
 * database checks that again, requires a recent verification and makes the creator the new Entity's OWNER. */
export function CreateEntityForm({ stepUpHref }: { stepUpHref: string }) {
  const [state, action, pending] = useActionState(createEntityAction, idleTimeSettingsState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <p className="hint">
        Untuk usaha atau buku baru yang pembukuannya terpisah. Entity baru langsung mendapat daftar
        akun standar dan Anda menjadi pemiliknya. Memerlukan verifikasi ulang.{" "}
        <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
      </p>
      <label>
        Jenis
        <select name="entity_type" defaultValue="company">
          <option value="company">Buku usaha (PT, CV, atau usaha pribadi)</option>
          <option value="personal">Buku rumah tangga</option>
        </select>
      </label>
      <label>
        Nama Resmi
        <input name="legal_name" required maxLength={200} placeholder="mis. CV Contoh Abadi" />
      </label>
      <label>
        Nama Merek (opsional)
        <input name="brand_name" maxLength={200} />
      </label>
      <label>
        Kode (dipakai di alamat halaman; tidak bisa diubah)
        <input
          name="code"
          required
          minLength={2}
          maxLength={31}
          placeholder="mis. toko2"
          autoCapitalize="none"
          spellCheck={false}
        />
      </label>
      <p className="hint">
        Nama dan merek bisa diganti nanti; kode dan jenis tidak. Entity yang sudah dibuat tidak bisa
        dihapus.
      </p>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Membuat…" : "Tambah Entity"}
      </button>
    </form>
  );
}
