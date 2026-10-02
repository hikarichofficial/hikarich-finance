"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState, type ReactNode } from "react";
import { recurringRuleActions, type RecurringStatus } from "@/domain/planning/planning";
import {
  endRecurringRuleAction,
  pauseRecurringRuleAction,
  resumeRecurringRuleAction,
  runDueRecurringOccurrencesAction,
  type PlanningActionState,
} from "./actions";
import { idlePlanningActionState, idleRunDueActionState } from "./actionsState";

/**
 * Recurring Rule status actions (P13 Part 3h, fourth increment, Step 09 §13, §18), following the exact shape
 * `TransferActions.tsx` already established: a plain submit button for the action needing no reason (Resume,
 * the same shape `ConfirmForm` uses), and a reveal-then-confirm form with a reason gate (`reasonSchema`: 5
 * characters) for the two that do (Pause, End) -- the same shape `ReverseForm` uses for Transfer's own
 * irreversible action. `recurringRuleActions` (already the Detail screen's own eligibility source, previously
 * shown only as inert hint text) is this component's eligibility source too, so the hint sentence and the
 * buttons can never disagree. `RunDueRecurringOccurrencesButton` is a separate export: the manual "generate
 * now" RPC (`planning.recurring_run`) is entity-wide, not per-rule, so it belongs on the Register screen.
 */

function ResumeForm({ ruleId }: { ruleId: string }) {
  const [state, action, pending] = useActionState(
    resumeRecurringRuleAction,
    idlePlanningActionState,
  );
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="rule_id" value={ruleId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Melanjutkan…" : "Lanjutkan Aturan"}
      </button>
    </form>
  );
}

function ReasonGatedForm({
  ruleId,
  action,
  openLabel,
  hint,
  submitLabel,
  pendingLabel,
}: {
  ruleId: string;
  action: (
    previous: PlanningActionState,
    formData: FormData,
  ) => Promise<PlanningActionState> | PlanningActionState;
  openLabel: string;
  hint: string;
  submitLabel: string;
  pendingLabel: string;
}) {
  const [state, formAction, pending] = useActionState(action, idlePlanningActionState);
  const formActionForm = usePreservingForm(formAction, state);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        {openLabel}
      </button>
    );
  }

  return (
    <form {...formActionForm} className="invoice-action-form">
      <input type="hidden" name="rule_id" value={ruleId} />
      <p className="hint">{hint}</p>
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
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending || reason.trim().length < 5}>
          {pending ? pendingLabel : submitLabel}
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

export interface RecurringRuleActionPermissions {
  /** `planning.recurring_edit` -- covers pause, resume and end alike (the RPCs share one capability). */
  canManage: boolean;
}

export function RecurringRuleActions({
  ruleId,
  status,
  permissions,
}: {
  ruleId: string;
  status: RecurringStatus;
  permissions: RecurringRuleActionPermissions;
}) {
  const eligible = recurringRuleActions(status);
  const actions: ReactNode[] = [];
  if (eligible.canPause && permissions.canManage) {
    actions.push(
      <ReasonGatedForm
        key="pause"
        ruleId={ruleId}
        action={pauseRecurringRuleAction}
        openLabel="Jeda Aturan"
        hint="Aturan yang dijeda tidak akan menghasilkan kejadian baru sampai dilanjutkan."
        submitLabel="Jeda Aturan"
        pendingLabel="Menjeda…"
      />,
    );
  }
  if (eligible.canResume && permissions.canManage) {
    actions.push(<ResumeForm key="resume" ruleId={ruleId} />);
  }
  if (eligible.canEnd && permissions.canManage) {
    actions.push(
      <ReasonGatedForm
        key="end"
        ruleId={ruleId}
        action={endRecurringRuleAction}
        openLabel="Akhiri Aturan"
        hint="Aturan yang diakhiri tidak dapat dilanjutkan atau diedit lagi."
        submitLabel="Akhiri Aturan"
        pendingLabel="Mengakhiri…"
      />,
    );
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}

/** Register screen's manual "generate now" button (`planning.recurring_run`), entity-wide rather than
 * per-rule -- see the module doc comment above. */
export function RunDueRecurringOccurrencesButton({
  entityId,
  canRun,
}: {
  entityId: string;
  canRun: boolean;
}) {
  const [state, action, pending] = useActionState(
    runDueRecurringOccurrencesAction,
    idleRunDueActionState,
  );
  const actionForm = usePreservingForm(action, state);
  if (!canRun) return null;
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity_id" value={entityId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Menjalankan…" : "Jalankan yang Jatuh Tempo"}
      </button>
    </form>
  );
}
