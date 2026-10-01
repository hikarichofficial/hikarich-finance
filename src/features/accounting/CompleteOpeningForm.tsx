"use client";

import { useActionState } from "react";
import { completeOpeningBalancesAction, idleOpeningActionState } from "./openingBalanceActions";

/** Completes the opening balances (decision 245): `complete_opening_balances` records the clearing
 * account's residual and locks further opening postings for the Entity. */
export function CompleteOpeningForm({ entity }: { entity: string | undefined }) {
  const [state, action, pending] = useActionState(
    completeOpeningBalancesAction,
    idleOpeningActionState,
  );
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <p className="hint">
        Selesaikan setelah semua saldo awal (termasuk piutang, utang, aset, pinjaman) diposting.
        Setelah diselesaikan, saldo awal tidak dapat diposting lagi untuk entitas ini.
      </p>
      <label>
        Catatan penyelesaian (opsional)
        <input name="note" maxLength={500} />
      </label>
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-danger" disabled={pending}>
        {pending ? "Menyelesaikan…" : "Selesaikan Saldo Awal"}
      </button>
    </form>
  );
}
