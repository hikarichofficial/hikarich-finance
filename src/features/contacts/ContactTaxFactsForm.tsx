"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "react";
import { recordContactFactsAction } from "./contactActions";
import { idleContactActionState } from "./contactActionsState";

export interface ContactTaxFacts {
  effective_from: string;
  party_kind: string;
  residency: string;
  tax_id_status: string;
  pkp_status: string;
  wht_exemption: string;
}

/**
 * The contact's tax facts (Step 05 §3-§4, decision 258) through `tax_record_contact_facts`: effective-dated
 * and append-only, so saving again with a later date records a change and keeps the history. The engine
 * reads them to decide withholding (resident or not, tax number, exemption certificate).
 */
export function ContactTaxFactsForm({
  contactId,
  current,
  today,
}: {
  contactId: string;
  current: ContactTaxFacts | null;
  today: string;
}) {
  const [state, action, pending] = useActionState(recordContactFactsAction, idleContactActionState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="contact_id" value={contactId} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <label>
        Jenis Pihak
        <select name="party_kind" defaultValue={current?.party_kind ?? "company"}>
          <option value="company">Badan / perusahaan</option>
          <option value="individual">Orang pribadi</option>
          <option value="government">Instansi pemerintah</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Domisili Pajak
        <select name="residency" defaultValue={current?.residency ?? "resident"}>
          <option value="resident">Dalam negeri</option>
          <option value="non_resident">Luar negeri</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        NPWP
        <select name="tax_id_status" defaultValue={current?.tax_id_status ?? "unknown"}>
          <option value="has_npwp">Punya NPWP</option>
          <option value="no_npwp">Tidak punya NPWP</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Status PKP
        <select name="pkp_status" defaultValue={current?.pkp_status ?? "unknown"}>
          <option value="pkp">PKP</option>
          <option value="non_pkp">Bukan PKP</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Surat Keterangan Bebas Potong PPh
        <select name="wht_exemption" defaultValue={current?.wht_exemption ?? "none"}>
          <option value="none">Tidak ada</option>
          <option value="certificate">Ada (SKB)</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Catatan Bukti (opsional)
        <input name="evidence_note" maxLength={1000} placeholder="mis. salinan NPWP diterima" />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Data Pajak"}
      </button>
    </form>
  );
}
