"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useEffect, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { useRouter } from "next/navigation";
import type { ExpenseActionSet } from "@/domain/purchases/expenseList";
import {
  cancelExpenseAction,
  confirmExpenseAction,
  correctExpenseAction,
  recallExpenseAction,
  rejectExpenseAction,
  reverseExpenseAction,
  submitExpenseAction,
  type ExpenseActionState,
} from "./expenseActions";
import { idleExpenseActionState } from "./expenseActionsState";
import { ProblemNotice } from "@/features/feedback/ProblemNotice";

/**
 * Direct Expense status actions (Step 09 §12, decision 245), the same one-small-form-per-action shape
 * `BillActions.tsx` uses. Which actions appear comes from `expenseActions`, which mirrors the P6 RPC guards.
 */

type ServerAction = (state: ExpenseActionState, formData: FormData) => Promise<ExpenseActionState>;

function ErrorLine({
  state,
  editHref,
  fixHint,
}: {
  state: ExpenseActionState;
  editHref?: string;
  fixHint?: string;
}) {
  return state.status === "error" ? (
    <ProblemNotice
      message={state.message}
      targets={state.targets}
      editHref={editHref}
      fixHint={fixHint}
    />
  ) : null;
}

function SimpleAction({
  expenseId,
  serverAction,
  label,
  pendingLabel,
  variant = "primary",
  editHref,
}: {
  expenseId: string;
  serverAction: ServerAction;
  label: string;
  pendingLabel: string;
  variant?: "primary" | "secondary";
  /** The draft's edit form: a refusal that names a column links there with it marked red. */
  editHref?: string;
}) {
  const [state, action, pending] = useActionState(serverAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="expense_id" value={expenseId} />
      <ErrorLine state={state} editHref={editHref} />
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

function ReasonAction({
  expenseId,
  serverAction,
  label,
  pendingLabel,
  hint,
  minLength = 5,
}: {
  expenseId: string;
  serverAction: ServerAction;
  label: string;
  pendingLabel: string;
  hint: string;
  minLength?: number;
}) {
  const [state, action, pending] = useActionState(serverAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        {label}
      </button>
    );
  }
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="expense_id" value={expenseId} />
      <p className="hint">{hint}</p>
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
      <ErrorLine state={state} />
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

function ConfirmAction({
  expenseId,
  editHref,
}: {
  expenseId: string;
  editHref: string | undefined;
}) {
  const [state, action, pending] = useActionState(confirmExpenseAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  const [showDuplicate, setShowDuplicate] = useState(false);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="expense_id" value={expenseId} />
      <ErrorLine
        state={state}
        editHref={editHref}
        fixHint="Klik “Tarik Kembali ke Draf”, lalu “Ubah Draf”, dan perbaiki bagian yang disebut di atas."
      />
      {showDuplicate ? (
        <label>
          Alasan duplikat (isi hanya jika struk yang sama memang sengaja dicatat lagi)
          <textarea name="duplicate_reason" minLength={5} maxLength={1000} />
        </label>
      ) : state.status === "error" ? (
        <button type="button" className="btn-ghost" onClick={() => setShowDuplicate(true)}>
          Ini memang struk ganda yang disengaja
        </button>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Mengonfirmasi…" : "Konfirmasi & Posting"}
      </button>
    </form>
  );
}

function CorrectAction({ expenseId, entity }: { expenseId: string; entity: string | undefined }) {
  const [state, action, pending] = useActionState(correctExpenseAction, idleExpenseActionState);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const router = useRouter();
  useEffect(() => {
    if (state.status === "ok" && "newExpenseId" in state && state.newExpenseId) {
      const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";
      router.push(`/purchases/expenses/${state.newExpenseId}${suffix}`);
    }
  }, [state, router, entity]);
  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Koreksi
      </button>
    );
  }
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="expense_id" value={expenseId} />
      <p className="hint">
        Pengeluaran ini dibalik dan dibuat draf pengganti berisi sama untuk Anda perbaiki.
      </p>
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
      <ErrorLine state={state} />
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending || reason.trim().length < 5}>
          {pending ? "Mengoreksi…" : "Koreksi"}
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

export function ExpenseActions({
  expenseId,
  actions,
  entity,
  status,
}: {
  expenseId: string;
  actions: ExpenseActionSet;
  entity: string | undefined;
  /** Only a draft can be opened in the edit form. */
  status?: string;
}) {
  if (!Object.values(actions).some(Boolean)) return null;
  const editHref =
    status === "draft"
      ? `/purchases/expenses/${expenseId}/edit${entity ? `?entity=${encodeURIComponent(entity)}` : ""}`
      : undefined;
  return (
    <div className="invoice-actions">
      {actions.confirm ? <ConfirmAction expenseId={expenseId} editHref={editHref} /> : null}
      {actions.submit ? (
        <SimpleAction
          expenseId={expenseId}
          serverAction={submitExpenseAction}
          label="Ajukan untuk Persetujuan"
          pendingLabel="Mengajukan…"
          variant="secondary"
          editHref={editHref}
        />
      ) : null}
      {actions.recall ? (
        <SimpleAction
          expenseId={expenseId}
          serverAction={recallExpenseAction}
          label="Tarik Kembali ke Draf"
          pendingLabel="Menarik…"
          variant="secondary"
        />
      ) : null}
      {actions.reject ? (
        <ReasonAction
          expenseId={expenseId}
          serverAction={rejectExpenseAction}
          label="Tolak"
          pendingLabel="Menolak…"
          hint="Pengeluaran dikembalikan ke draf dengan alasan penolakan."
          minLength={3}
        />
      ) : null}
      {actions.cancel ? (
        <ReasonAction
          expenseId={expenseId}
          serverAction={cancelExpenseAction}
          label="Batalkan"
          pendingLabel="Membatalkan…"
          hint="Pengeluaran yang belum dikonfirmasi ini dibatalkan tanpa dampak akuntansi."
        />
      ) : null}
      {actions.reverse ? (
        <ReasonAction
          expenseId={expenseId}
          serverAction={reverseExpenseAction}
          label="Balik (Reverse)"
          pendingLabel="Membalik…"
          hint="Jurnal dan mutasi kas pengeluaran ini dibalik. Tindakan ini tidak dapat diurungkan."
        />
      ) : null}
      {actions.correct ? <CorrectAction expenseId={expenseId} entity={entity} /> : null}
    </div>
  );
}
