"use client";

import { useActionState, useEffect, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import {
  approveBillAction,
  cancelBillAction,
  correctBillAction,
  idleBillActionState,
  idleCorrectBillState,
  recallBillAction,
  rejectBillAction,
  submitBillAction,
  voidBillAction,
} from "./actions";

/**
 * Bill Detail's status actions (Step 09 §12), following the exact shape `src/features/sales/InvoiceActions.tsx`
 * established in Part 3a: one small form per action, `useActionState` for error display, a reason gate that
 * mirrors the database's own minimum before submitting.
 */

function SimpleActionForm({
  billId,
  action,
  pending,
  state,
  label,
  pendingLabel,
  variant = "primary",
}: {
  billId: string;
  action: (formData: FormData) => void;
  pending: boolean;
  state: { status: "idle" | "ok" | "error"; message?: string };
  label: string;
  pendingLabel: string;
  variant?: "primary" | "secondary";
}) {
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="bill_id" value={billId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button
        type="submit"
        className={variant === "primary" ? "btn-primary" : "btn-secondary"}
        disabled={pending}
      >
        {pending ? pendingLabel : label}
      </button>
    </form>
  );
}

function ReasonActionForm({
  billId,
  action,
  pending,
  state,
  label,
  pendingLabel,
  confirmHint,
  minLength = 5,
}: {
  billId: string;
  action: (formData: FormData) => void;
  pending: boolean;
  state: { status: "idle" | "ok" | "error"; message?: string };
  label: string;
  pendingLabel: string;
  confirmHint: string;
  minLength?: number;
}) {
  const [reason, setReason] = useState("");
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button
        type="button"
        className="btn-secondary"
        onClick={() => setOpen(true)}
      >
        {label}
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="bill_id" value={billId} />
      <p className="hint">{confirmHint}</p>
      <label>
        Alasan (minimal {minLength} karakter)
        <textarea
          name="reason"
          required
          minLength={minLength}
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
        <button
          type="submit"
          className="btn-danger"
          disabled={pending || reason.trim().length < minLength}
        >
          {pending ? pendingLabel : label}
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

function SubmitForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    submitBillAction,
    idleBillActionState,
  );
  return (
    <SimpleActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Ajukan untuk Persetujuan"
      pendingLabel="Mengajukan…"
    />
  );
}

function RecallForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    recallBillAction,
    idleBillActionState,
  );
  return (
    <SimpleActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Tarik Kembali ke Draf"
      pendingLabel="Menarik…"
      variant="secondary"
    />
  );
}

function ApproveForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    approveBillAction,
    idleBillActionState,
  );
  return (
    <SimpleActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Setujui Tagihan"
      pendingLabel="Menyetujui…"
    />
  );
}

function RejectForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    rejectBillAction,
    idleBillActionState,
  );
  return (
    <ReasonActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Tolak Tagihan"
      pendingLabel="Menolak…"
      confirmHint="Tagihan akan dikembalikan ke pengaju dengan alasan penolakan."
      minLength={3}
    />
  );
}

function CancelForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    cancelBillAction,
    idleBillActionState,
  );
  return (
    <ReasonActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Batalkan Tagihan"
      pendingLabel="Membatalkan…"
      confirmHint="Tagihan draf/menunggu ini dibatalkan tanpa dampak akuntansi dan tidak pernah menerima nomor."
    />
  );
}

function VoidForm({ billId }: { billId: string }) {
  const [state, action, pending] = useActionState(
    voidBillAction,
    idleBillActionState,
  );
  return (
    <ReasonActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Batalkan Tagihan (Void)"
      pendingLabel="Membatalkan…"
      confirmHint="Tagihan yang sudah disetujui akan dibatalkan (void) dan jurnal pembaliknya dibuat. Tidak dapat diurungkan."
    />
  );
}

function CorrectForm({ billId }: { billId: string }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(
    correctBillAction,
    idleCorrectBillState,
  );
  useEffect(() => {
    if (state.status === "ok" && state.newBillId) {
      router.push(`/purchases/bills/${state.newBillId}`);
    }
  }, [state, router]);
  return (
    <ReasonActionForm
      billId={billId}
      action={action}
      pending={pending}
      state={state}
      label="Koreksi Tagihan"
      pendingLabel="Mengoreksi…"
      confirmHint="Tagihan ini akan dibatalkan (void) dan draf pengganti dengan isi yang sama akan dibuka untuk diedit."
    />
  );
}

export interface BillActionPermissions {
  canSubmit: boolean;
  canEdit: boolean;
  canApprove: boolean;
  canVoid: boolean;
  canCorrect: boolean;
}

/**
 * Only a draft bill can be submitted or cancelled-as-edit; only a submitted bill can be recalled, rejected
 * or approved; only an approved bill can be voided or corrected -- each RPC's own migration refuses any
 * other status (`CONFLICT: only a ... bill can be ...`), so the button set here mirrors that exactly rather
 * than guessing from the generic workflow shape.
 */
export function BillActions({
  billId,
  status,
  permissions,
}: {
  billId: string;
  status: "draft" | "submitted" | "approved" | "cancelled" | "void";
  permissions: BillActionPermissions;
}) {
  const actions: ReactNode[] = [];
  if (status === "draft" && permissions.canSubmit) {
    actions.push(<SubmitForm key="submit" billId={billId} />);
  }
  if (status === "submitted" && permissions.canEdit) {
    actions.push(<RecallForm key="recall" billId={billId} />);
  }
  if (
    (status === "draft" || status === "submitted") &&
    permissions.canApprove
  ) {
    actions.push(<ApproveForm key="approve" billId={billId} />);
  }
  if (status === "submitted" && permissions.canApprove) {
    actions.push(<RejectForm key="reject" billId={billId} />);
  }
  if (status === "approved" && permissions.canCorrect) {
    actions.push(<CorrectForm key="correct" billId={billId} />);
  }
  if (status === "approved" && permissions.canVoid) {
    actions.push(<VoidForm key="void" billId={billId} />);
  }
  if (
    (status === "draft" || status === "submitted") &&
    (permissions.canEdit || permissions.canVoid)
  ) {
    actions.push(<CancelForm key="cancel" billId={billId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
