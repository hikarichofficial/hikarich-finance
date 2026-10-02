"use client";

import { useActionState, useState } from "react";
import type { PeriodStatus } from "@/schemas/accounting";
import {
  beginPeriodCloseAction,
  cancelPeriodCloseAction,
  closePeriodAction,
  reopenPeriodAction,
} from "./actions";
import { idlePeriodActionState } from "./actionsState";

/**
 * Accounting Periods Detail's status actions (P13, Step 09 §14), the exact same shape `JournalActions`/
 * `TransferActions` already established: one small form per action, `useActionState` for error display.
 */

function SimpleActionForm({
  periodId,
  action,
  label,
  pendingLabel,
  className = "btn-primary",
}: {
  periodId: string;
  action: typeof beginPeriodCloseAction;
  label: string;
  pendingLabel: string;
  className?: string;
}) {
  const [state, formAction, pending] = useActionState(action, idlePeriodActionState);
  return (
    <form action={formAction} className="invoice-action-form">
      <input type="hidden" name="period_id" value={periodId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className={className} disabled={pending}>
        {pending ? pendingLabel : label}
      </button>
    </form>
  );
}

function ReopenForm({ periodId }: { periodId: string }) {
  const [state, action, pending] = useActionState(reopenPeriodAction, idlePeriodActionState);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Buka Kembali Periode
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="period_id" value={periodId} />
      <p className="hint">
        Membuka kembali periode yang sudah ditutup memerlukan verifikasi ulang (step-up) dan alasan
        tertulis. Tindakan ini tercatat dalam audit.
      </p>
      <label>
        Alasan (minimal 10 karakter)
        <textarea
          name="reason"
          required
          minLength={10}
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
          disabled={pending || reason.trim().length < 10}
        >
          {pending ? "Membuka kembali…" : "Buka Kembali Periode"}
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

export interface PeriodActionPermissions {
  canClose: boolean;
  canReopen: boolean;
}

export function PeriodActions({
  periodId,
  status,
  permissions,
}: {
  periodId: string;
  status: PeriodStatus;
  permissions: PeriodActionPermissions;
}) {
  const actions = [];
  if (permissions.canClose && (status === "open" || status === "reopened")) {
    actions.push(
      <SimpleActionForm
        key="begin"
        periodId={periodId}
        action={beginPeriodCloseAction}
        label="Mulai Tinjauan Penutupan"
        pendingLabel="Memulai…"
      />,
    );
  }
  if (permissions.canClose && status === "closing_review") {
    actions.push(
      <SimpleActionForm
        key="close"
        periodId={periodId}
        action={closePeriodAction}
        label="Tutup Periode"
        pendingLabel="Menutup…"
      />,
    );
    actions.push(
      <SimpleActionForm
        key="cancel"
        periodId={periodId}
        action={cancelPeriodCloseAction}
        label="Batalkan Tinjauan"
        pendingLabel="Membatalkan…"
        className="btn-secondary"
      />,
    );
  }
  if (permissions.canReopen && status === "closed") {
    actions.push(<ReopenForm key="reopen" periodId={periodId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
