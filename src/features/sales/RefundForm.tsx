"use client";

import { useActionState, useState } from "react";
import { trimDecimalText } from "@/domain/money/format";
import type { SettlementAccountOption } from "@/features/shared/SettlementForm";
import { createRefundAction } from "./actions";
import { idleInvoiceActionState } from "./actionsState";

export interface RefundOptionView {
  key: string;
  source: "allocation" | "advance";
  allocationId: string | null;
  label: string;
  refundable: string;
}

/**
 * Refund part or all of a confirmed payment (Step 07 §3, decision 263) through `create_refund` with
 * immediate confirmation (`refunds.create` and `refunds.confirm`). One amount per refundable part: what
 * was applied to each invoice, and any unapplied advance. The database checks every amount against what
 * is still refundable and posts the cash, accounting and tax consequences together.
 */
export function RefundForm({
  paymentId,
  options,
  accounts,
  today,
}: {
  paymentId: string;
  options: readonly RefundOptionView[];
  accounts: readonly SettlementAccountOption[];
  today: string;
}) {
  const [state, action, pending] = useActionState(createRefundAction, idleInvoiceActionState);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Refund ke Pelanggan
      </button>
    );
  }

  return (
    <form action={action} className="record-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="option_count" value={options.length} />
      {options.map((option, index) => (
        <label key={option.key}>
          {option.label} (maksimal {trimDecimalText(option.refundable)})
          <input type="hidden" name={`source_${index}`} value={option.source} />
          <input type="hidden" name={`allocation_${index}`} value={option.allocationId ?? ""} />
          <input name={`amount_${index}`} inputMode="decimal" placeholder="0" />
        </label>
      ))}
      <label>
        Dibayar dari Rekening
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
        Tanggal Refund
        <input type="date" name="refund_date" required defaultValue={today} />
      </label>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <label>
        Nomor Referensi Transfer (opsional)
        <input name="reference" maxLength={200} />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Refund"}
      </button>
    </form>
  );
}
