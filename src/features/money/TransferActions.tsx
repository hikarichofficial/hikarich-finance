"use client";

import { useActionState, useState, type ReactNode } from "react";
import {
  cancelTransferAction,
  confirmTransferAction,
  idleTransferActionState,
  reverseTransferAction,
} from "./transferActions";

/**
 * Transfer Detail's status actions (Step 09 §13), following the exact shape `BillActions.tsx`/
 * `InvoiceActions.tsx` already established: one small form per action, `useActionState` for error display, a
 * reason gate for Reverse that mirrors the database's own minimum (`reverseTransferInputSchema`: 5 chars).
 */

function SimpleActionForm({
  transferId,
  action,
  pending,
  state,
  label,
  pendingLabel,
}: {
  transferId: string;
  action: (formData: FormData) => void;
  pending: boolean;
  state: { status: "idle" | "ok" | "error"; message?: string };
  label: string;
  pendingLabel: string;
}) {
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="transfer_id" value={transferId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? pendingLabel : label}
      </button>
    </form>
  );
}

function ConfirmForm({ transferId }: { transferId: string }) {
  const [state, action, pending] = useActionState(
    confirmTransferAction,
    idleTransferActionState,
  );
  return (
    <SimpleActionForm
      transferId={transferId}
      action={action}
      pending={pending}
      state={state}
      label="Konfirmasi Transfer"
      pendingLabel="Mengonfirmasi…"
    />
  );
}

function CancelForm({ transferId }: { transferId: string }) {
  const [state, action, pending] = useActionState(
    cancelTransferAction,
    idleTransferActionState,
  );
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  if (!open) {
    return (
      <button
        type="button"
        className="btn-secondary"
        onClick={() => setOpen(true)}
      >
        Batalkan Transfer
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="transfer_id" value={transferId} />
      <p className="hint">
        Draf transfer ini dibatalkan tanpa dampak akuntansi.
      </p>
      <label>
        Alasan (opsional)
        <textarea
          name="reason"
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
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Membatalkan…" : "Batalkan Transfer"}
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

function ReverseForm({ transferId }: { transferId: string }) {
  const [state, action, pending] = useActionState(
    reverseTransferAction,
    idleTransferActionState,
  );
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const today = new Date().toISOString().slice(0, 10);

  if (!open) {
    return (
      <button
        type="button"
        className="btn-secondary"
        onClick={() => setOpen(true)}
      >
        Balik Transfer (Reverse)
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="transfer_id" value={transferId} />
      <p className="hint">
        Transfer yang sudah dikonfirmasi akan dibalik dengan jurnal pembalik dan
        pergerakan kas pembalik. Tidak dapat diurungkan.
      </p>
      <label>
        Tanggal Pembalikan
        <input type="date" name="reversal_date" defaultValue={today} required />
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
        <button
          type="submit"
          className="btn-danger"
          disabled={pending || reason.trim().length < 5}
        >
          {pending ? "Membalik…" : "Balik Transfer"}
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

export interface TransferActionPermissions {
  canConfirm: boolean;
  canCancel: boolean;
  canReverse: boolean;
}

/** Only a draft transfer can be confirmed or cancelled; only a confirmed transfer can be reversed -- each
 * RPC's own migration refuses any other status, so the button set here mirrors that exactly (decision
 * 162/167's precedent) rather than guessing from the generic workflow shape. */
export function TransferActions({
  transferId,
  status,
  permissions,
}: {
  transferId: string;
  status: "draft" | "confirmed" | "reversed" | "cancelled";
  permissions: TransferActionPermissions;
}) {
  const actions: ReactNode[] = [];
  if (status === "draft" && permissions.canConfirm) {
    actions.push(<ConfirmForm key="confirm" transferId={transferId} />);
  }
  if (status === "draft" && permissions.canCancel) {
    actions.push(<CancelForm key="cancel" transferId={transferId} />);
  }
  if (status === "confirmed" && permissions.canReverse) {
    actions.push(<ReverseForm key="reverse" transferId={transferId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
