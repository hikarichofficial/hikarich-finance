"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import { reverseVendorPaymentAction } from "./actions";
import { idleReverseVendorPaymentState } from "./actionsState";
import { todayInBusinessZone } from "@/lib/time";

/**
 * Payment Made Detail's only status action. Mirrors `PaymentActions.tsx`'s own Sales-side `ReverseForm`
 * exactly, gated on `bills.pay` (the RPC's own permission -- see `VendorPaymentDetailScreen.tsx`'s
 * comment for why there is nothing else to wire here yet).
 */

function ReverseForm({ paymentId }: { paymentId: string }) {
  const [state, action, pending] = useActionState(
    reverseVendorPaymentAction,
    idleReverseVendorPaymentState,
  );
  const actionForm = usePreservingForm(action, state);
  const [reason, setReason] = useState("");
  const [open, setOpen] = useState(false);
  const today = todayInBusinessZone();

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
          maxLength={1000}
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

export interface VendorPaymentActionPermissions {
  canReverse: boolean;
}

export function VendorPaymentActions({
  paymentId,
  status,
  permissions,
}: {
  paymentId: string;
  status: "confirmed" | "reversed";
  permissions: VendorPaymentActionPermissions;
}) {
  if (status !== "confirmed" || !permissions.canReverse) return null;
  return (
    <div className="invoice-actions">
      <ReverseForm paymentId={paymentId} />
    </div>
  );
}
