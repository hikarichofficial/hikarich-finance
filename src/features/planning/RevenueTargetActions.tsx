"use client";

import { useActionState, useState, type ReactNode } from "react";
import { budgetActions } from "@/domain/planning/budgetList";
import type { PlanStatus } from "@/domain/planning/planning";
import { activateRevenueTargetAction, closeRevenueTargetAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";

/**
 * Revenue Target Detail's status actions (P13 Part 3h, fourth increment, Step 09 §13, §18). Same shape as
 * `BudgetActions.tsx` -- Revenue Target shares `PlanStatus` and the identical draft/active/closed rule with
 * Budget (decision 184), so `budgetActions` is reused rather than duplicated here. Activate is a plain submit
 * button; Close is terminal, so it gets a reveal-then-confirm gate, without a reason field since
 * `close_revenue_target` does not accept one.
 */

function ActivateForm({ targetId }: { targetId: string }) {
  const [state, action, pending] = useActionState(
    activateRevenueTargetAction,
    idlePlanningActionState,
  );
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="target_id" value={targetId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Mengaktifkan…" : "Aktifkan Target"}
      </button>
    </form>
  );
}

function CloseForm({ targetId }: { targetId: string }) {
  const [state, action, pending] = useActionState(
    closeRevenueTargetAction,
    idlePlanningActionState,
  );
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Tutup Target
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="target_id" value={targetId} />
      <p className="hint">Target pendapatan yang ditutup tidak dapat dibuka atau diedit lagi.</p>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Menutup…" : "Tutup Target"}
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

export interface RevenueTargetActionPermissions {
  /** `planning.budget_edit` -- shared with Budget (decision 184). */
  canManage: boolean;
}

export function RevenueTargetActions({
  targetId,
  status,
  permissions,
}: {
  targetId: string;
  status: PlanStatus;
  permissions: RevenueTargetActionPermissions;
}) {
  const eligible = budgetActions(status);
  const actions: ReactNode[] = [];
  if (eligible.canActivate && permissions.canManage) {
    actions.push(<ActivateForm key="activate" targetId={targetId} />);
  }
  if (eligible.canClose && permissions.canManage) {
    actions.push(<CloseForm key="close" targetId={targetId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
