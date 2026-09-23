"use client";

import { useActionState, useEffect, useState, type ReactNode } from "react";
import { useRouter } from "next/navigation";
import {
  correctInvoiceAction,
  ensureInvoiceLinkAction,
  idleCorrectInvoiceState,
  idleInvoiceActionState,
  idleInvoiceLinkState,
  issueInvoiceAction,
  voidInvoiceAction,
} from "./actions";

/**
 * Invoice Detail's status actions (Step 09 §11). Each action is its own small form so a mistaken click
 * cannot fire the wrong RPC, and reasons are checked against the database's own 5-character minimum
 * (`reasonSchema`, Step 08 §18) before submitting so the error usually never has to round-trip.
 */

function IssueForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(issueInvoiceAction, idleInvoiceActionState);
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menerbitkan…" : "Terbitkan Faktur"}
      </button>
    </form>
  );
}

function ReasonForm({
  invoiceId,
  action,
  pending,
  state,
  label,
  pendingLabel,
  confirmHint,
}: {
  invoiceId: string;
  action: (formData: FormData) => void;
  pending: boolean;
  state: { status: "idle" | "ok" | "error"; message?: string };
  label: string;
  pendingLabel: string;
  confirmHint: string;
}) {
  const [reason, setReason] = useState("");
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        {label}
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <p className="hint">{confirmHint}</p>
      <label>
        Alasan (minimal 5 karakter)
        <textarea
          name="reason"
          required
          minLength={5}
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
        <button type="submit" className="btn-danger" disabled={pending || reason.trim().length < 5}>
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

function VoidForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(voidInvoiceAction, idleInvoiceActionState);
  return (
    <ReasonForm
      invoiceId={invoiceId}
      action={action}
      pending={pending}
      state={state}
      label="Batalkan Faktur"
      pendingLabel="Membatalkan…"
      confirmHint="Faktur yang diterbitkan akan dibatalkan (void) dan jurnal pembaliknya dibuat. Tindakan ini tidak dapat diurungkan."
    />
  );
}

function CorrectForm({ invoiceId }: { invoiceId: string }) {
  const router = useRouter();
  const [state, action, pending] = useActionState(correctInvoiceAction, idleCorrectInvoiceState);
  useEffect(() => {
    if (state.status === "ok" && state.newInvoiceId) {
      router.push(`/sales/invoices/${state.newInvoiceId}`);
    }
  }, [state, router]);
  return (
    <ReasonForm
      invoiceId={invoiceId}
      action={action}
      pending={pending}
      state={state}
      label="Koreksi Faktur"
      pendingLabel="Mengoreksi…"
      confirmHint="Faktur ini akan dibatalkan (void) dan draf pengganti dengan isi yang sama akan dibuka untuk diedit."
    />
  );
}

function CopyLinkForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(ensureInvoiceLinkAction, idleInvoiceLinkState);
  const [copied, setCopied] = useState(false);
  const url =
    state.token && typeof window !== "undefined"
      ? `${window.location.origin}/i/${state.token}`
      : null;

  async function copy() {
    if (!url) return;
    try {
      await navigator.clipboard.writeText(url);
      setCopied(true);
    } catch {
      setCopied(false);
    }
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {url ? (
        <div className="invoice-link-row">
          <input
            type="text"
            readOnly
            value={url}
            onFocus={(event) => event.currentTarget.select()}
          />
          <button type="button" className="btn-secondary" onClick={copy}>
            {copied ? "Tersalin" : "Salin"}
          </button>
        </div>
      ) : (
        <button type="submit" className="btn-secondary" disabled={pending}>
          {pending ? "Membuat tautan…" : "Salin Tautan Publik"}
        </button>
      )}
    </form>
  );
}

export interface InvoiceActionPermissions {
  canIssue: boolean;
  canVoid: boolean;
  canCorrect: boolean;
  canManageLink: boolean;
}

/**
 * Only an issued invoice can be voided, corrected or linked publicly (P5's `void_invoice`/`correct_invoice`/
 * `regenerate_invoice_link` all refuse any other status -- `CONFLICT: only an issued invoice...`). Step 09
 * §11 separately says a public preview should be available before Issue; the already-shipped P5 RPC does
 * not allow that, so this stays issued-only pending an OWNER decision (see DECISIONS, Open items).
 */
export function InvoiceActions({
  invoiceId,
  status,
  permissions,
}: {
  invoiceId: string;
  status: "draft" | "issued" | "cancelled" | "void";
  permissions: InvoiceActionPermissions;
}) {
  const actions: ReactNode[] = [];
  if (status === "draft" && permissions.canIssue) {
    actions.push(<IssueForm key="issue" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canManageLink) {
    actions.push(<CopyLinkForm key="link" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canCorrect) {
    actions.push(<CorrectForm key="correct" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canVoid) {
    actions.push(<VoidForm key="void" invoiceId={invoiceId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
