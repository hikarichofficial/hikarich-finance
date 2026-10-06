"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { trimDecimalText } from "@/domain/money/format";
import type { SettlementAccountOption } from "@/features/shared/SettlementForm";
import { createDraftRefundAction, createRefundAction } from "./actions";
import { idleInvoiceActionState } from "./actionsState";
import { MoneyInput } from "@/features/shared/MoneyInput";

export interface RefundOptionView {
  key: string;
  source: "allocation" | "advance";
  allocationId: string | null;
  label: string;
  refundable: string;
}

/**
 * Refund part or all of a confirmed payment (Step 07 §3, decision 263). One amount per refundable part:
 * what was applied to each invoice, and any unapplied advance. The database checks every amount against
 * what is still refundable and posts the cash, accounting and tax consequences together -- at once when
 * `immediate` (a person holding both `refunds.create` and `refunds.confirm`), or as a draft waiting in the
 * Menunggu Konfirmasi list below when not (`refunds.create` alone, decision 263's deferred item, closed by
 * decision 285): the database RPC is the same `create_refund` either way, only `p_confirm` differs.
 */
export function RefundForm({
  paymentId,
  options,
  accounts,
  today,
  immediate,
}: {
  paymentId: string;
  options: readonly RefundOptionView[];
  accounts: readonly SettlementAccountOption[];
  today: string;
  /** True for a person holding both `refunds.create` and `refunds.confirm` (confirms at once); false for
   * `refunds.create` alone (saves a draft for someone else to confirm or reject). */
  immediate: boolean;
}) {
  const [state, action, pending] = useActionState(
    immediate ? createRefundAction : createDraftRefundAction,
    idleInvoiceActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Refund ke Pelanggan
      </button>
    );
  }

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="option_count" value={options.length} />
      {options.map((option, index) => (
        <label key={option.key}>
          {option.label} (maksimal {trimDecimalText(option.refundable)})
          <input type="hidden" name={`source_${index}`} value={option.source} />
          <input type="hidden" name={`allocation_${index}`} value={option.allocationId ?? ""} />
          <MoneyInput name={`amount_${index}`} placeholder="0" />
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
        {pending ? "Menyimpan…" : immediate ? "Simpan Refund" : "Simpan sebagai Draft"}
      </button>
    </form>
  );
}
