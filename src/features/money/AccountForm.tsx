"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import { createAccountAction } from "./accountActions";
import { idleAccountActionState } from "./accountActionsState";

/**
 * Add Account (Step 09 §13, decision 258) through `create_financial_account`. The ledger account behind it
 * is created by the database; the starting balance is entered afterwards through Opening Balances or a
 * balance adjustment, never typed here.
 */
export function AccountForm({
  entity,
  baseCurrency,
}: {
  entity: string | undefined;
  baseCurrency: string;
}) {
  const [state, action, pending] = useActionState(createAccountAction, idleAccountActionState);
  const actionForm = usePreservingForm(action, state);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Jenis
        <select name="kind" defaultValue="bank">
          <option value="bank">Bank</option>
          <option value="cash">Kas tunai</option>
          <option value="ewallet">E-wallet / saldo marketplace</option>
        </select>
      </label>
      <label>
        Nama Rekening
        <input name="name" required maxLength={120} placeholder="mis. BCA Operasional" />
      </label>
      <label>
        Mata Uang
        <input name="currency" required maxLength={3} defaultValue={baseCurrency} />
      </label>
      <label>
        Nama Bank / Penyedia (opsional)
        <input name="institution_name" maxLength={120} />
      </label>
      <label>
        Nomor Rekening (opsional)
        <input name="account_number" maxLength={60} />
      </label>
      <label>
        Atas Nama (opsional)
        <input name="account_holder" maxLength={120} />
      </label>
      <p className="hint">Saldo awal diisi setelah ini lewat Saldo Awal atau Penyesuaian Saldo.</p>
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
