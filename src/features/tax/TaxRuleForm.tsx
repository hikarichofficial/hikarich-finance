"use client";

import Link from "next/link";
import { useActionState } from "react";
import { RULE_FAMILY_LABELS } from "@/domain/tax/tax";
import type { RuleFormDefaults } from "@/domain/tax/ruleAuthoring";
import { ruleFamilyLabel } from "@/domain/tax/taxRulesList";
import { idleRuleActionState, saveRuleDraftAction, type RuleActionState } from "./taxRuleActions";

export function RuleActionResult({
  state,
  stepUpHref,
}: {
  state: RuleActionState;
  stepUpHref: string;
}) {
  if (state.status !== "error") return null;
  return (
    <div role="alert" className="error">
      <p>
        {state.message}
        {state.stepUp ? (
          <>
            {" "}
            <Link href={stepUpHref}>Verifikasi sekarang</Link>.
          </>
        ) : null}
      </p>
      {state.detail ? <p className="hint">Detail dari sistem: {state.detail}</p> : null}
    </div>
  );
}

/** Create or edit a tax rule draft (decision 249). A new version starts as a copy of the rule it adjusts;
 * the database checks the parameters for the rule's family when the draft is saved. */
export function TaxRuleForm({
  defaults,
  entity,
  stepUpHref,
  cancelHref,
}: {
  defaults: RuleFormDefaults;
  entity: string | undefined;
  stepUpHref: string;
  cancelHref: string;
}) {
  const [state, action, pending] = useActionState(saveRuleDraftAction, idleRuleActionState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="rule_id" value={defaults.ruleId ?? ""} />
      {defaults.lockedIdentity ? (
        <>
          <input type="hidden" name="family" value={defaults.family} />
          <input type="hidden" name="code" value={defaults.code} />
          <p className="hint">
            Kelompok: {ruleFamilyLabel(defaults.family)} · Kode: {defaults.code}
          </p>
        </>
      ) : (
        <>
          <label>
            Kelompok
            <select name="family" defaultValue={defaults.family}>
              {Object.entries(RULE_FAMILY_LABELS).map(([value, label]) => (
                <option key={value} value={value}>
                  {label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Kode aturan
            <input name="code" defaultValue={defaults.code} required minLength={2} maxLength={80} />
          </label>
        </>
      )}
      <label>
        Berlaku sejak
        <input type="date" name="effective_from" defaultValue={defaults.effectiveFrom} required />
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="is_repeal" defaultChecked={defaults.isRepeal} />
        Versi ini mencabut aturan (tidak berlaku lagi sejak tanggal di atas)
      </label>
      <label>
        Parameter (JSON)
        <textarea
          name="params"
          defaultValue={defaults.paramsText}
          rows={12}
          spellCheck={false}
          className="code-input"
        />
      </label>
      <p className="hint">
        Ubah hanya nilai yang berubah (misalnya tarif). Sistem memeriksa bentuk parameter sesuai
        kelompok aturan saat draf disimpan.
      </p>
      <label>
        Judul sumber hukum
        <input name="source_title" defaultValue={defaults.sourceTitle} required minLength={3} maxLength={300} />
      </label>
      <label>
        Nomor/pasal referensi
        <input name="source_ref" defaultValue={defaults.sourceRef} maxLength={200} />
      </label>
      <label>
        Tautan sumber (https)
        <input type="url" name="source_url" defaultValue={defaults.sourceUrl} maxLength={500} />
      </label>
      <label>
        Diverifikasi pada
        <input type="date" name="verified_on" defaultValue={defaults.verifiedOn} required />
      </label>
      <label>
        Status verifikasi
        <select name="verification_status" defaultValue={defaults.verificationStatus}>
          <option value="needs_review">Perlu ditinjau</option>
          <option value="verified">Terverifikasi dengan sumber resmi</option>
        </select>
      </label>
      <label>
        Catatan
        <textarea name="notes" defaultValue={defaults.notes} rows={3} maxLength={2000} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan draf"}
        </button>{" "}
        <Link href={cancelHref}>Batal</Link>
      </div>
      <RuleActionResult state={state} stepUpHref={stepUpHref} />
    </form>
  );
}
