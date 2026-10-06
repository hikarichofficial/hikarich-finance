"use client";

import { useActionState } from "@/features/feedback/useActionState";
import { importBatchActions } from "@/domain/imports/imports";
import type { ImportBatchStatus } from "@/schemas/imports";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { commitImportAction, rollbackImportAction, validateImportAction } from "./importActions";
import { idleImportActionState, type ImportActionState } from "./importActionsState";

function Outcome({ state }: { state: ImportActionState }) {
  if (state.status === "idle") return null;
  return (
    <p
      role={state.status === "error" ? "alert" : "status"}
      className={state.status === "error" ? "error" : "hint"}
    >
      {state.message}
    </p>
  );
}

/**
 * Check again / Apply / Undo for one import batch (Step 08 §19, decision 275). Which button shows follows
 * the batch status; the database re-checks the status, the permission and what can safely be undone.
 */
export function ImportBatchActions({
  batchId,
  status,
  validRows,
}: {
  batchId: string;
  status: ImportBatchStatus;
  validRows: number;
}) {
  const can = importBatchActions(status);
  const [validateState, validateAction, validating] = useActionState(
    validateImportAction,
    idleImportActionState,
  );
  const [commitState, commitAction, committing] = useActionState(
    commitImportAction,
    idleImportActionState,
  );
  const [rollbackState, rollbackAction, rollingBack] = useActionState(
    rollbackImportAction,
    idleImportActionState,
  );
  const rollbackForm = usePreservingForm(rollbackAction, rollbackState);

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Tindakan</h2>
      </div>
      {can.canValidate ? (
        <form action={validateAction} className="record-form">
          <input type="hidden" name="batch_id" value={batchId} />
          <button type="submit" className="btn-secondary" disabled={validating}>
            {validating ? "Memeriksa…" : "Periksa Ulang"}
          </button>
        </form>
      ) : null}
      <Outcome state={validateState} />
      {can.canCommit ? (
        <form action={commitAction} className="record-form">
          <input type="hidden" name="batch_id" value={batchId} />
          <p className="hint">
            {validRows > 0
              ? `${validRows} baris valid akan masuk ke pembukuan. Baris tidak valid dan duplikat dilewati.`
              : "Tidak ada baris valid. Perbaiki tabelnya lalu impor ulang."}
          </p>
          <button type="submit" className="btn-primary" disabled={committing || validRows === 0}>
            {committing ? "Menerapkan…" : "Terapkan ke Pembukuan"}
          </button>
        </form>
      ) : null}
      <Outcome state={commitState} />
      {can.canRollback ? (
        <form {...rollbackForm} className="record-form">
          <input type="hidden" name="batch_id" value={batchId} />
          <label>
            Alasan pembatalan
            <input name="reason" required minLength={3} maxLength={1000} />
          </label>
          <button type="submit" className="btn-danger" disabled={rollingBack}>
            {rollingBack ? "Membatalkan…" : "Batalkan Impor Ini"}
          </button>
        </form>
      ) : null}
      <Outcome state={rollbackState} />
      {!can.canValidate && !can.canCommit && !can.canRollback ? (
        <p className="hint">Batch ini sudah dibatalkan; tidak ada tindakan lagi.</p>
      ) : null}
    </section>
  );
}
