"use client";

import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import {
  createPaymentLinkAction,
  updatePaymentLinkAction,
  type PaymentLinkActionState,
} from "./paymentLinkActions";
import { idlePaymentLinkActionState } from "./paymentLinkActionsState";
import type { PaymentLinkRow } from "@/services/sales/paymentLinks";

function Feedback({ state }: { state: PaymentLinkActionState }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/** Add a payment link (decision 307): a name and the https address of a payment gateway page. */
export function PaymentLinkCreateForm({ entity }: { entity: string | undefined }) {
  const [state, action, pending] = useActionState(
    createPaymentLinkAction,
    idlePaymentLinkActionState,
  );
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Nama Tautan
        <input
          name="name"
          required
          minLength={2}
          maxLength={120}
          placeholder="mis. Xendit - Invoice Umum"
        />
      </label>
      <label>
        Alamat Tautan (https://…)
        <input
          name="url"
          type="url"
          required
          maxLength={500}
          pattern="https://\S+"
          placeholder="https://checkout.example.com/pay/abc"
        />
      </label>
      <p className="hint">
        Pelanggan menekan tombol “Bayar sekarang” di invoice dan dibawa ke halaman ini. Pembayaran
        yang masuk tetap Anda catat sendiri di Pembayaran Diterima.
      </p>
      <Feedback state={state} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Tambah Tautan"}
      </button>
    </form>
  );
}

/** Change a link's name or address, or switch it off (a switched-off link is no longer offered on new invoices;
 * invoices already issued keep the address they were issued with). */
export function PaymentLinkEditForm({
  entity,
  link,
}: {
  entity: string | undefined;
  link: PaymentLinkRow;
}) {
  const [state, action, pending] = useActionState(
    updatePaymentLinkAction,
    idlePaymentLinkActionState,
  );
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="id" value={link.id} />
      <label>
        Nama Tautan
        <input name="name" required minLength={2} maxLength={120} defaultValue={link.name} />
      </label>
      <label>
        Alamat Tautan (https://…)
        <input
          name="url"
          type="url"
          required
          maxLength={500}
          pattern="https://\S+"
          defaultValue={link.payment_url}
        />
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="active" defaultChecked={link.is_active} /> Aktif (boleh dipilih
        di invoice baru)
      </label>
      <Feedback state={state} />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Perubahan"}
      </button>
    </form>
  );
}
