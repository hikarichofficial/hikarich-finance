"use client";

import { useActionState, useState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { sendPaymentReceiptEmailAction } from "./actions";
import { idleSendReceiptEmailState } from "./actionsState";

/** "Kirim Bukti Pembayaran ke Email" on Payment Detail. The address is pre-filled from the customer's own
 * e-mail but always editable, and the form stays after a send so the receipt can be sent again. */
export function SendReceiptEmailForm({
  paymentId,
  entity,
  defaultEmail,
  configured,
}: {
  paymentId: string;
  entity: string | undefined;
  defaultEmail: string | null;
  configured: boolean;
}) {
  const [state, action, pending] = useActionState(
    sendPaymentReceiptEmailAction,
    idleSendReceiptEmailState,
  );
  const actionForm = usePreservingForm(action, state);
  const [email, setEmail] = useState(defaultEmail ?? "");

  if (!configured) {
    return (
      <p className="hint">
        Pengiriman email belum diaktifkan untuk situs ini. Setelah OWNER memasang kunci Resend,
        bukti pembayaran dapat dikirim dari sini.
      </p>
    );
  }
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Kirim Bukti Pembayaran ke Email
        <input
          type="email"
          name="email"
          required
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          placeholder="nama@contoh.com"
        />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-secondary" disabled={pending || email.trim() === ""}>
        {pending ? "Mengirim…" : "Kirim Bukti Pembayaran"}
      </button>
    </form>
  );
}
