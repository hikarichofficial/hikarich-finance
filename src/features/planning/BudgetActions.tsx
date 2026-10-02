"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState, type ReactNode } from "react";
import { budgetActions } from "@/domain/planning/budgetList";
import type { PlanStatus } from "@/domain/planning/planning";
import { activateBudgetAction, closeBudgetAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";

/**
 * Budget Detail's status actions (P13 Part 3h, fourth increment, Step 09 §13, §18), following the exact
 * shape `TransferActions.tsx` already established. Activate needs no confirmation gate -- a plain submit
 * button, the same shape `ConfirmForm` uses for Transfer's own non-destructive action. Close is terminal (a
 * closed Budget can never be reopened, per `budgetList.ts`'s own PLAN_STATUS_TONE comment) so it gets a
 * reveal-then-confirm gate like `CancelForm`, without a reason field since `close_budget` does not accept
 * one.
 */

function ActivateForm({ budgetId }: { budgetId: string }) {
  const [state, action, pending] = useActionState(activateBudgetAction, idlePlanningActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="budget_id" value={budgetId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Mengaktifkan…" : "Aktifkan Anggaran"}
      </button>
    </form>
  );
}

function CloseForm({ budgetId }: { budgetId: string }) {
  const [state, action, pending] = useActionState(closeBudgetAction, idlePlanningActionState);
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Tutup Anggaran
      </button>
    );
  }

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="budget_id" value={budgetId} />
      <p className="hint">Anggaran yang ditutup tidak dapat dibuka atau diedit lagi.</p>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Menutup…" : "Tutup Anggaran"}
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

export interface BudgetActionPermissions {
  /** `planning.budget_edit` -- shared by activate and close alike (decision 184). */
  canManage: boolean;
}

export function BudgetActions({
  budgetId,
  status,
  permissions,
}: {
  budgetId: string;
  status: PlanStatus;
  permissions: BudgetActionPermissions;
}) {
  const eligible = budgetActions(status);
  const actions: ReactNode[] = [];
  if (eligible.canActivate && permissions.canManage) {
    actions.push(<ActivateForm key="activate" budgetId={budgetId} />);
  }
  if (eligible.canClose && permissions.canManage) {
    actions.push(<CloseForm key="close" budgetId={budgetId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
