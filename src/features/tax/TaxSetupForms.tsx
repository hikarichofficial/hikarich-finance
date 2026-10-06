"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import type { TaxOverview } from "@/schemas/tax";
import {
  activateTaxEngineAction,
  recordTaxProfileAction,
  type TaxSetupState,
} from "./taxSetupActions";
import { idleTaxSetupState } from "./taxSetupActionsState";

function Feedback({ state, next }: { state: TaxSetupState; next: string }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}{" "}
      {state.stepUp ? (
        <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(next)}`}>
          Verifikasi ulang →
        </StepUpLink>
      ) : null}
    </p>
  );
}

/**
 * The Entity's tax profile (Step 05 §3-§4, decision 258): effective-dated and append-only -- saving with a
 * later date records a change (for example becoming PKP) and keeps the history, so documents dated before
 * it keep the treatment they had.
 */
export function TaxProfileForm({
  entity,
  profile,
  today,
  next,
}: {
  entity: string | undefined;
  profile: TaxOverview["profile"];
  today: string;
  next: string;
}) {
  const [state, action, pending] = useActionState(recordTaxProfileAction, idleTaxSetupState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <label>
        Jenis Wajib Pajak
        <select
          name="taxpayer_kind"
          defaultValue={profile?.taxpayer_kind ?? "perseroan_perorangan"}
        >
          <option value="perseroan_perorangan">PT Perorangan (Perseroan Perorangan)</option>
          <option value="individual">Orang pribadi</option>
          <option value="company">PT / CV / badan lain</option>
          <option value="cooperative">Koperasi</option>
          <option value="other">Lainnya</option>
        </select>
      </label>
      <label>
        Skema Pajak Penghasilan
        <select name="income_regime" defaultValue={profile?.income_regime ?? "final_umkm"}>
          <option value="final_umkm">PPh Final UMKM</option>
          <option value="general">Tarif umum</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Dikecualikan dari PPh Final UMKM?
        <select name="umkm_exclusion" defaultValue={profile?.umkm_exclusion ?? "none"}>
          <option value="none">Tidak</option>
          <option value="excluded">Ya (mis. pekerjaan bebas)</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Omzet Digabung dengan Usaha Lain (keluarga / PT Perorangan lain)?
        <select name="aggregation_status" defaultValue={profile?.aggregation_status ?? "none"}>
          <option value="none">Tidak</option>
          <option value="applies">Ya</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Status PPN
        <select name="vat_status" defaultValue={profile?.vat_status ?? "non_pkp"}>
          <option value="non_pkp">Belum PKP (PPN tidak dihitung)</option>
          <option value="pkp">PKP (PPN dihitung otomatis)</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Wajib Memotong PPh (PPh 23, 4(2), 26)?
        <select name="withholding_agent" defaultValue={profile?.withholding_agent ?? "yes"}>
          <option value="yes">Ya (badan, atau orang pribadi yang ditunjuk)</option>
          <option value="no">Tidak</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        NPWP (opsional; disimpan terenkripsi)
        <input name="tax_identifier" maxLength={40} />
      </label>
      <label>
        Catatan Bukti (opsional)
        <input name="evidence_note" maxLength={1000} placeholder="mis. SK PKP nomor ..." />
      </label>
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Profil Pajak"}
      </button>
    </form>
  );
}

/** The engine switch (OWNER, recent step-up): from this date documents get their tax determined; earlier
 * ones are never re-evaluated. */
export function TaxEngineForm({
  entity,
  today,
  next,
}: {
  entity: string | undefined;
  today: string;
  next: string;
}) {
  const [state, action, pending] = useActionState(activateTaxEngineAction, idleTaxSetupState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Hitung Pajak Otomatis Mulai Tanggal
        <input type="date" name="from" required defaultValue={today} />
      </label>
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Mengaktifkan…" : "Aktifkan Mesin Pajak"}
      </button>
    </form>
  );
}
