"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import { reversePaymentAction } from "./actions";
import { idleReversePaymentState } from "./actionsState";

/**
 * Payment Detail's status actions. `reverse_payment` is the only lifecycle action with anything to wire up
 * here: refund creation is its own, later queue-screen-level increment (Step 09 §11's "Payment confirmation
 * queue... accessible from Sales and Attention/Tasks", the same scope note `InvoiceActions.tsx` already
 * carries for Confirm Payment/Refund). The database itself checks `invoices.confirm_payment` (the RPC's
 * own gate -- there is no separate `payments.reverse` permission key) and refuses a payment that still has
 * confirmed refunds against it ("reverse them first"); this form does not attempt to pre-check that second
 * condition client-side, matching this codebase's own "let the database be the one source of business
 * truth" rule -- it is surfaced through `errorState`'s generic `AuthzError`/fallback-message mapping.
 */

function ReverseForm({ paymentId }: { paymentId: string }) {
  const [state, action, pending] = useActionState(reversePaymentAction, idleReversePaymentState);
  const actionForm = usePreservingForm(action, state);
  const [reason, setReason] = useState("");
  const [open, setOpen] = useState(false);
  const today = new Date().toISOString().slice(0, 10);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Balik Pembayaran
      </button>
    );
  }

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <p className="hint">
        Pembayaran ini akan dibalik (reverse) dan jurnal pembaliknya dibuat. Tindakan ini tidak
        dapat diurungkan.
      </p>
      <label>
        Tanggal Pembalikan
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Alasan (minimal 5 karakter)
        <textarea
          name="reason"
          required
          minLength={5}
          maxLength={500}
          value={reason}
          onChange={(event) => setReason(event.target.value)}
        />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending || reason.trim().length < 5}>
          {pending ? "Membalik…" : "Balik Pembayaran"}
        </button>
        <button
          type="button"
          className="btn-ghost"
          onClick={() => setOpen(false)}
          disabled={pending}
        >
          Batal
        </button>
      </div>
    </form>
  );
}

export interface PaymentActionPermissions {
  canReverse: boolean;
}

export function PaymentActions({
  paymentId,
  status,
  permissions,
}: {
  paymentId: string;
  status: "confirmed" | "reversed";
  permissions: PaymentActionPermissions;
}) {
  if (status !== "confirmed" || !permissions.canReverse) return null;
  return (
    <div className="invoice-actions">
      <ReverseForm paymentId={paymentId} />
    </div>
  );
}
