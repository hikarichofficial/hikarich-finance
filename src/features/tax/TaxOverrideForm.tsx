"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import Link from "next/link";
import { useActionState, useState } from "react";
import {
  setTaxOverrideAction,
  withdrawTaxOverrideAction,
  type TaxOverrideState,
} from "./taxOverrideActions";
import { MoneyInput } from "@/features/shared/MoneyInput";

const IDLE: TaxOverrideState = { status: "idle" };

/** Replace one tax result of a document that is not recognised yet (Step 05 §15, decision 262). */
export function TaxOverrideForm({
  sourceType,
  sourceId,
  kinds,
  next,
}: {
  sourceType: "invoice" | "bill" | "expense";
  sourceId: string;
  kinds: readonly { value: string; label: string }[];
  next: string;
}) {
  const [state, action, pending] = useActionState(setTaxOverrideAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  if (kinds.length === 0) return null;
  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Koreksi Manual Pajak
      </button>
    );
  }
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="source_type" value={sourceType} />
      <input type="hidden" name="source_id" value={sourceId} />
      <input type="hidden" name="path" value={next.split("?")[0]} />
      <label>
        Pajak yang Dikoreksi
        <select name="kind" defaultValue={kinds[0]?.value}>
          {kinds.map((kind) => (
            <option key={kind.value} value={kind.value}>
              {kind.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Jumlah Pajak yang Benar
        <MoneyInput name="amount" required placeholder="0" />
      </label>
      <label>
        Alasan (minimal 10 karakter)
        <textarea name="reason" required minLength={10} maxLength={1000} />
      </label>
      <label>
        Catatan Bukti (mis. nomor surat / dokumen)
        <input name="evidence_note" required minLength={5} maxLength={1000} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}{" "}
          {state.stepUp ? (
            <Link href={`/auth/step-up?next=${encodeURIComponent(next)}`}>Verifikasi ulang →</Link>
          ) : null}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Koreksi"}
      </button>
    </form>
  );
}

/** Withdraw one active override (`tax_override_withdraw`): the engine's own result applies again. */
export function TaxOverrideWithdrawForm({
  overrideId,
  label,
  next,
}: {
  overrideId: string;
  label: string;
  next: string;
}) {
  const [state, action, pending] = useActionState(withdrawTaxOverrideAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  if (!open) {
    return (
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        Tarik Koreksi {label}
      </button>
    );
  }
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="override_id" value={overrideId} />
      <input type="hidden" name="path" value={next.split("?")[0]} />
      <p className="hint">
        Koreksi manual {label} dicabut dan perhitungan otomatis berlaku lagi. Perlu verifikasi
        ulang.
      </p>
      <label>
        Alasan (minimal 5 karakter)
        <textarea name="reason" required minLength={5} maxLength={500} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}{" "}
          {state.stepUp ? (
            <Link href={`/auth/step-up?next=${encodeURIComponent(next)}`}>Verifikasi ulang →</Link>
          ) : null}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Menarik…" : "Tarik Koreksi"}
      </button>
    </form>
  );
}
