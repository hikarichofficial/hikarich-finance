"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import {
  cancelRefundAction,
  confirmRefundAction,
  rejectRefundAction,
  reverseRefundAction,
} from "./actions";
import { idleInvoiceActionState } from "./actionsState";

/**
 * Confirm/Reject/Cancel/Reverse a refund record (decision 263's own deferred item, closed here): a draft
 * refund -- one saved by a person who holds `refunds.create` alone, via the new draft path on `RefundForm`
 * -- otherwise has no screen to act on it. A `draft` offers Confirm/Reject to whoever holds
 * `refunds.confirm` and Cancel to whoever holds `refunds.create` (the RPC's own guard, not narrowed to the
 * original creator); a `confirmed` refund offers Reverse to whoever holds `refunds.confirm`. Every other
 * status (`rejected`/`cancelled`/`reversed`) is terminal and offers nothing -- the caller shows its badge,
 * not this component.
 */
export function RefundActionForms({
  refundId,
  paymentId,
  status,
  canConfirm,
  canCreate,
  today,
}: {
  refundId: string;
  paymentId: string;
  status: "draft" | "confirmed";
  canConfirm: boolean;
  canCreate: boolean;
  today: string;
}) {
  const [confirmState, confirmAction, confirming] = useActionState(
    confirmRefundAction,
    idleInvoiceActionState,
  );
  const confirmActionForm = usePreservingForm(confirmAction, confirmState);
  const [rejectState, rejectAction, rejecting] = useActionState(
    rejectRefundAction,
    idleInvoiceActionState,
  );
  const rejectActionForm = usePreservingForm(rejectAction, rejectState);
  const [cancelState, cancelAction, cancelling] = useActionState(
    cancelRefundAction,
    idleInvoiceActionState,
  );
  const cancelActionForm = usePreservingForm(cancelAction, cancelState);
  const [reverseState, reverseAction, reversing] = useActionState(
    reverseRefundAction,
    idleInvoiceActionState,
  );
  const reverseActionForm = usePreservingForm(reverseAction, reverseState);
  const [mode, setMode] = useState<"closed" | "confirm" | "reject" | "cancel" | "reverse">(
    "closed",
  );

  if (status === "draft" && !canConfirm && !canCreate) return null;
  if (status === "confirmed" && !canConfirm) return null;

  if (mode === "closed") {
    return (
      <div className="invoice-actions">
        {status === "draft" && canConfirm ? (
          <>
            <button type="button" className="btn-primary" onClick={() => setMode("confirm")}>
              Konfirmasi
            </button>
            <button type="button" className="btn-secondary" onClick={() => setMode("reject")}>
              Tolak
            </button>
          </>
        ) : null}
        {status === "draft" && canCreate ? (
          <button type="button" className="btn-ghost" onClick={() => setMode("cancel")}>
            Batalkan
          </button>
        ) : null}
        {status === "confirmed" && canConfirm ? (
          <button type="button" className="btn-secondary" onClick={() => setMode("reverse")}>
            Balik Refund
          </button>
        ) : null}
      </div>
    );
  }

  if (mode === "confirm") {
    return (
      <form {...confirmActionForm} className="record-form">
        <input type="hidden" name="refund_id" value={refundId} />
        <input type="hidden" name="payment_id" value={paymentId} />
        {confirmState.status === "error" ? (
          <p role="alert" className="error">
            {confirmState.message}
          </p>
        ) : null}
        <button type="submit" className="btn-primary" disabled={confirming}>
          {confirming ? "Menyimpan…" : "Konfirmasi Refund"}
        </button>
      </form>
    );
  }

  if (mode === "reject") {
    return (
      <form {...rejectActionForm} className="record-form">
        <input type="hidden" name="refund_id" value={refundId} />
        <input type="hidden" name="payment_id" value={paymentId} />
        <label>
          Alasan Penolakan (minimal 5 karakter)
          <input name="reason" required minLength={5} maxLength={500} />
        </label>
        {rejectState.status === "error" ? (
          <p role="alert" className="error">
            {rejectState.message}
          </p>
        ) : null}
        <button type="submit" className="btn-secondary" disabled={rejecting}>
          {rejecting ? "Menyimpan…" : "Tolak Refund"}
        </button>
      </form>
    );
  }

  if (mode === "cancel") {
    return (
      <form {...cancelActionForm} className="record-form">
        <input type="hidden" name="refund_id" value={refundId} />
        <input type="hidden" name="payment_id" value={paymentId} />
        <label>
          Alasan Pembatalan (minimal 5 karakter)
          <input name="reason" required minLength={5} maxLength={500} />
        </label>
        {cancelState.status === "error" ? (
          <p role="alert" className="error">
            {cancelState.message}
          </p>
        ) : null}
        <button type="submit" className="btn-ghost" disabled={cancelling}>
          {cancelling ? "Menyimpan…" : "Batalkan Draft"}
        </button>
      </form>
    );
  }

  return (
    <form {...reverseActionForm} className="record-form">
      <input type="hidden" name="refund_id" value={refundId} />
      <input type="hidden" name="payment_id" value={paymentId} />
      <label>
        Tanggal Pembalikan
        <input type="date" name="date" required defaultValue={today} />
      </label>
      <label>
        Alasan (minimal 5 karakter)
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      {reverseState.status === "error" ? (
        <p role="alert" className="error">
          {reverseState.message}
        </p>
      ) : null}
      <button type="submit" className="btn-secondary" disabled={reversing}>
        {reversing ? "Menyimpan…" : "Balik Refund"}
      </button>
    </form>
  );
}
