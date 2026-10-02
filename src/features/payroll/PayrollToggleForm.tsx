"use client";

import { useActionState, useState, type ReactNode } from "react";
import type { PayrollActionState } from "./payrollActions";

const IDLE: PayrollActionState = { status: "idle" };

export type PayrollFormAction = (
  previous: PayrollActionState,
  formData: FormData,
) => Promise<PayrollActionState>;

/** A form that opens from a button and posts its fields to one Payroll server action. */
export function PayrollToggleForm({
  action,
  openLabel,
  submitLabel,
  primary,
  children,
}: {
  action: PayrollFormAction;
  openLabel: string;
  submitLabel: string;
  primary?: boolean;
  children: ReactNode;
}) {
  const [state, formAction, pending] = useActionState(action, IDLE);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button
        type="button"
        className={primary ? "btn-primary" : "btn-secondary"}
        onClick={() => setOpen(true)}
      >
        {openLabel}
      </button>
    );
  }

  return (
    <form action={formAction} className="record-form">
      <strong>{openLabel}</strong>
      {children}
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
      <button type="button" className="btn-secondary" onClick={() => setOpen(false)}>
        Tutup
      </button>
    </form>
  );
}
