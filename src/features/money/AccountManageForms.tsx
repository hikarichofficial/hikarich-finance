"use client";

import { useActionState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { deleteAccountAction, setAccountActiveAction } from "./accountActions";
import { idleAccountActionState } from "./accountActionsState";

function Feedback({ state }: { state: { status: string; message?: string } }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/**
 * Hapus Rekening (OWNER request, 5 October 2026). Opens a confirmation panel first; the database only accepts
 * the delete while the account has no history at all, otherwise the message says to disable it instead.
 */
export function DeleteAccountForm({
  entity,
  accountId,
  accountName,
}: {
  entity: string | undefined;
  accountId: string;
  accountName: string;
}) {
  const [state, action, pending] = useActionState(deleteAccountAction, idleAccountActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <details className="account-danger">
      <summary className="btn-danger">Hapus Rekening</summary>
      <form {...actionForm} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="account_id" value={accountId} />
        <p>
          Rekening <strong>{accountName}</strong> akan dihapus permanen. Ini hanya bisa dilakukan
          bila rekening belum pernah dipakai (belum ada transaksi sama sekali).
        </p>
        <label>
          Alasan (opsional)
          <input name="reason" maxLength={200} placeholder="mis. salah input" />
        </label>
        <label className="checkbox-field">
          <input type="checkbox" name="confirm" value="yes" required /> Ya, hapus rekening ini
        </label>
        <Feedback state={state} />
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Menghapus…" : "Hapus Rekening"}
        </button>
      </form>
    </details>
  );
}

/** Nonaktifkan / aktifkan kembali -- the way to retire an account that already has transactions. */
export function ToggleAccountActiveForm({
  entity,
  accountId,
  isActive,
}: {
  entity: string | undefined;
  accountId: string;
  isActive: boolean;
}) {
  const [state, action, pending] = useActionState(setAccountActiveAction, idleAccountActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="account_id" value={accountId} />
      <input type="hidden" name="active" value={isActive ? "false" : "true"} />
      {isActive ? (
        <label>
          Alasan menonaktifkan
          <input
            name="reason"
            required
            minLength={5}
            maxLength={200}
            placeholder="mis. rekening ditutup"
          />
        </label>
      ) : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "…" : isActive ? "Nonaktifkan Rekening" : "Aktifkan Kembali"}
      </button>
      <Feedback state={state} />
    </form>
  );
}
