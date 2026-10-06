"use client";

import { useActionState, useEffect, useRef } from "react";
import { Drawer } from "@/features/shell/Drawer";
import { quickCreatePaymentLinkAction } from "./paymentLinkActions";
import { idleQuickPaymentLinkState } from "./paymentLinkActionsState";

/**
 * Add-a-payment-link-on-the-spot Drawer for Buat Invoice (decision 307), like the quick add of a customer: the
 * person types the name and the https address of the gateway page and the new link is selected on the invoice at
 * once. The same links are managed under Penjualan > Tautan Pembayaran.
 */
export function QuickAddPaymentLinkDrawer({
  entity,
  open,
  onClose,
  onCreated,
}: {
  entity: string | undefined;
  open: boolean;
  onClose: () => void;
  onCreated: (link: { id: string; name: string }) => void;
}) {
  const [state, formAction, pending] = useActionState(
    quickCreatePaymentLinkAction,
    idleQuickPaymentLinkState,
  );
  const formRef = useRef<HTMLFormElement>(null);
  // Guards against re-firing onCreated when the Drawer re-renders while `state` still holds the last success.
  const handledId = useRef<string | null>(null);

  useEffect(() => {
    if (state.status === "ok" && state.link && handledId.current !== state.link.id) {
      handledId.current = state.link.id;
      onCreated(state.link);
      formRef.current?.reset();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onCreated is re-created each render
  }, [state]);

  return (
    <Drawer open={open} onClose={onClose} title="Tambah Tautan Pembayaran">
      <form ref={formRef} action={formAction} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <label>
          Nama Tautan
          <input
            name="name"
            required
            minLength={2}
            maxLength={120}
            autoComplete="off"
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
            autoComplete="off"
            placeholder="https://checkout.example.com/pay/abc"
          />
        </label>
        <p className="hint">
          Pelanggan menekan “Bayar sekarang” di invoice dan dibawa ke halaman ini. Pembayaran tetap
          Anda catat sendiri.
        </p>
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}
        <div>
          <button type="submit" className="btn-primary" disabled={pending}>
            {pending ? "Menyimpan…" : "Simpan & Gunakan"}
          </button>
        </div>
      </form>
    </Drawer>
  );
}
