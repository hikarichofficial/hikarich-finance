"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { usePathname, useSearchParams } from "next/navigation";
import { useState, type ReactNode } from "react";
import { useActionState } from "@/features/feedback/useActionState";
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
  wide,
  alwaysOpen,
  children,
}: {
  action: PayrollFormAction;
  openLabel: string;
  submitLabel: string;
  primary?: boolean;
  /** A form with a row editor inside: the 480px cap of `.record-form` is lifted. */
  wide?: boolean;
  /** The form is the content of its own page (an employee sub-page): no opening button, no "Tutup". */
  alwaysOpen?: boolean;
  children: ReactNode;
}) {
  const [state, formAction, pending] = useActionState(action, IDLE);
  const formActionForm = usePreservingForm(formAction, state);
  const [open, setOpen] = useState(false);
  const pathname = usePathname();
  const search = useSearchParams().toString();
  const stepUpNext = search === "" ? pathname : `${pathname}?${search}`;

  if (!open && !alwaysOpen) {
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
    <form {...formActionForm} className={wide ? "record-form record-form-wide" : "record-form"}>
      {alwaysOpen ? null : <strong>{openLabel}</strong>}
      {children}
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}{" "}
          {state.stepUp ? (
            <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(stepUpNext)}`}>
              Verifikasi ulang →
            </StepUpLink>
          ) : null}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
      {alwaysOpen ? null : (
        <button type="button" className="btn-secondary" onClick={() => setOpen(false)}>
          Tutup
        </button>
      )}
    </form>
  );
}
