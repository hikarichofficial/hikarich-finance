"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import { trimDecimalText } from "@/domain/money/format";
import { MoneyInput } from "@/features/shared/MoneyInput";

export interface SettlementAccountOption {
  id: string;
  label: string;
}

interface SettlementState {
  status: "idle" | "ok" | "error";
  message?: string;
}

/**
 * One small form for "money against one document" (decision 258): Record Payment on an invoice and Pay
 * Bill. It opens from a button, defaults the amount to what is outstanding, and posts to the given server
 * action, which calls the unmodified payment RPC with a single allocation to this document.
 */
export function SettlementForm({
  action,
  idName,
  id,
  accounts,
  outstanding,
  today,
  openLabel,
  submitLabel,
  accountLabel,
}: {
  action: (previous: SettlementState, formData: FormData) => Promise<SettlementState>;
  idName: string;
  id: string;
  accounts: readonly SettlementAccountOption[];
  outstanding: string;
  today: string;
  openLabel: string;
  submitLabel: string;
  accountLabel: string;
}) {
  const [state, formAction, pending] = useActionState(action, { status: "idle" });
  const formActionForm = usePreservingForm(formAction, state);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-primary" onClick={() => setOpen(true)}>
        {openLabel}
      </button>
    );
  }

  return (
    <form {...formActionForm} className="record-form">
      <input type="hidden" name={idName} value={id} />
      <label>
        {accountLabel}
        <select name="account_id" required defaultValue="">
          <option value="" disabled>
            Pilih rekening kas/bank
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal
        <input type="date" name="payment_date" required defaultValue={today} />
      </label>
      <label>
        Jumlah
        <MoneyInput name="amount" required defaultValue={trimDecimalText(outstanding)} />
      </label>
      <label>
        Nomor Referensi / Bukti Transfer (opsional)
        <input name="reference" maxLength={200} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
    </form>
  );
}
