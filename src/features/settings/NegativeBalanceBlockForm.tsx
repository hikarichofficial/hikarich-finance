"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import Link from "next/link";
import { useActionState } from "react";
import { setNegativeBalanceBlockAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

const KIND_OPTIONS: ReadonlyArray<{ value: "bank" | "cash" | "ewallet"; label: string }> = [
  { value: "bank", label: "Bank" },
  { value: "cash", label: "Kas tunai" },
  { value: "ewallet", label: "E-wallet / saldo marketplace" },
];

/** Which account kinds may never go negative (decision 55, OWNER answer 4 October 2026): a transaction
 * that would take a blocked kind's account below zero is rejected by `record_movement` itself (P4). Unset
 * blocks nothing; this form is the first and only way to change it other than a direct database update. */
export function NegativeBalanceBlockForm({
  entity,
  blockedKinds,
  stepUpHref,
}: {
  entity: string | undefined;
  blockedKinds: readonly string[];
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(
    setNegativeBalanceBlockAction,
    idleTimeSettingsState,
  );
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <p className="hint">
        Jenis akun yang dicentang tidak akan pernah bisa minus: transaksi yang membuat saldonya di
        bawah nol akan ditolak sistem. Tidak dicentang berarti hanya peringatan, transaksi tetap
        boleh jalan. Perubahan memerlukan verifikasi ulang dalam 30 menit terakhir.{" "}
        <Link href={stepUpHref}>Verifikasi sekarang</Link>.
      </p>
      {KIND_OPTIONS.map((option) => (
        <label key={option.value}>
          <input
            type="checkbox"
            name="kind"
            value={option.value}
            defaultChecked={blockedKinds.includes(option.value)}
          />{" "}
          {option.label}
        </label>
      ))}
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan"}
        </button>
      </div>
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
          {state.stepUp ? (
            <>
              {" "}
              <Link href={stepUpHref}>Verifikasi sekarang</Link>.
            </>
          ) : null}
        </p>
      ) : null}
    </form>
  );
}
