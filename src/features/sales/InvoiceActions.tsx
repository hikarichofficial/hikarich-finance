"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useEffect, useState, type ReactNode } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { useRouter } from "next/navigation";
import {
  cancelInvoiceDraftAction,
  correctInvoiceAction,
  ensureInvoiceLinkAction,
  issueInvoiceAction,
  revokeInvoiceLinkAction,
  sendInvoiceEmailAction,
  setInvoiceLinkExpiryAction,
  voidInvoiceAction,
} from "./actions";
import {
  idleCorrectInvoiceState,
  idleInvoiceActionState,
  idleInvoiceLinkState,
  idleSendInvoiceEmailState,
} from "./actionsState";

/**
 * Invoice Detail's status actions (Step 09 §11). Each action is its own small form so a mistaken click
 * cannot fire the wrong RPC, and reasons are checked against the database's own 5-character minimum
 * (`reasonSchema`, Step 08 §18) before submitting so the error usually never has to round-trip.
 */

function IssueForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(issueInvoiceAction, idleInvoiceActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menerbitkan…" : "Terbitkan Invoice"}
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
      label="Batalkan Invoice"
      pendingLabel="Membatalkan…"
      confirmHint="Invoice yang diterbitkan akan dibatalkan (void) dan jurnal pembaliknya dibuat. Tindakan ini tidak dapat diurungkan."
    />
  );
}

/** Revoke the public link (Step 07 §4, decision 259): the address stops working at once; "Salin Tautan
 * Publik" afterwards creates a new one. */
function RevokeLinkForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(revokeInvoiceLinkAction, idleInvoiceActionState);
  return (
    <ReasonForm
      invoiceId={invoiceId}
      action={action}
      pending={pending}
      state={state}
      label="Cabut Tautan Publik"
      pendingLabel="Mencabut…"
      confirmHint="Tautan yang sudah dibagikan langsung tidak bisa dibuka lagi. Invoice dan riwayatnya tidak berubah."
    />
  );
}

/** Cancel a draft (`cancel_invoice`, `invoices.edit` for a draft): nothing was posted, so there is no
 * journal to reverse; the draft is kept as cancelled with its reason. */
function CancelDraftForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(cancelInvoiceDraftAction, idleInvoiceActionState);
  return (
    <ReasonForm
      invoiceId={invoiceId}
      action={action}
      pending={pending}
      state={state}
      label="Batalkan Draf"
      pendingLabel="Membatalkan…"
      confirmHint="Draf ini akan dibatalkan dan tidak bisa diterbitkan lagi. Tidak ada dampak akuntansi."
    />
  );
}

/** Set when the public link stops working (`set_invoice_link_expiry`); an empty time means no expiry. The
 * browser's local time is converted to an exact instant here, because the server does not know the
 * person's time zone. */
function LinkExpiryForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(
    setInvoiceLinkExpiryAction,
    idleInvoiceActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  const [localTime, setLocalTime] = useState("");
  const parsed = localTime === "" ? null : new Date(localTime);
  const expiresAt = parsed && !Number.isNaN(parsed.getTime()) ? parsed.toISOString() : "";

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Atur Masa Berlaku Tautan
      </button>
    );
  }

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <input type="hidden" name="expires_at" value={expiresAt} />
      <label>
        Tautan Berlaku Sampai (kosongkan = tanpa batas waktu)
        <input
          type="datetime-local"
          value={localTime}
          onChange={(event) => setLocalTime(event.target.value)}
        />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Masa Berlaku"}
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
      label="Koreksi Invoice"
      pendingLabel="Mengoreksi…"
      confirmHint="Invoice ini akan dibatalkan (void) dan draf pengganti dengan isi yang sama akan dibuka untuk diedit."
    />
  );
}

function CopyLinkForm({ invoiceId }: { invoiceId: string }) {
  const [state, action, pending] = useActionState(ensureInvoiceLinkAction, idleInvoiceLinkState);
  const actionForm = usePreservingForm(action, state);
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
    <form {...actionForm} className="invoice-action-form">
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

/** Send Invoice via Email (decision 279's open item): kept alongside, never instead of, "Salin Tautan
 * Publik" above -- both share the exact same public link. The email field is pre-filled from the
 * customer's own `contacts.email` when one is on file, but always editable, so a one-off address never
 * needs to be saved to the contact first. */
function SendInvoiceEmailForm({
  invoiceId,
  defaultEmail,
}: {
  invoiceId: string;
  defaultEmail: string | null;
}) {
  const [state, action, pending] = useActionState(
    sendInvoiceEmailAction,
    idleSendInvoiceEmailState,
  );
  const actionForm = usePreservingForm(action, state);
  const [email, setEmail] = useState(defaultEmail ?? "");

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="invoice_id" value={invoiceId} />
      <label>
        Kirim / Kirim Ulang Invoice ke Email
        <input
          type="email"
          name="email"
          required
          value={email}
          onChange={(event) => setEmail(event.target.value)}
          placeholder="nama@contoh.com"
        />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
      <button type="submit" className="btn-secondary" disabled={pending || email.trim() === ""}>
        {pending ? "Mengirim…" : "Kirim via Email"}
      </button>
    </form>
  );
}

export interface InvoiceActionPermissions {
  canIssue: boolean;
  canVoid: boolean;
  canCorrect: boolean;
  canManageLink: boolean;
  /** Cancelling a DRAFT needs `invoices.edit` (`cancel_invoice`'s own check for a draft). */
  canCancelDraft?: boolean;
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
  email,
}: {
  invoiceId: string;
  status: "draft" | "issued" | "cancelled" | "void";
  permissions: InvoiceActionPermissions;
  /** Absent when the caller skipped loading it (e.g. no `canManageLink`); `configured: false` means the
   * OWNER has not set up Resend yet (decision 279's open item) -- the form is replaced by a plain hint,
   * the same "show a hint instead of a form that can only fail" pattern Document Storage already uses. */
  email?: { configured: boolean; defaultEmail: string | null };
}) {
  const actions: ReactNode[] = [];
  if (status === "draft" && permissions.canIssue) {
    actions.push(<IssueForm key="issue" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canManageLink) {
    actions.push(<CopyLinkForm key="link" invoiceId={invoiceId} />);
    if (email?.configured) {
      actions.push(
        <SendInvoiceEmailForm
          key="email"
          invoiceId={invoiceId}
          defaultEmail={email.defaultEmail}
        />,
      );
    } else if (email) {
      actions.push(
        <p key="email-disabled" className="hint">
          Pengiriman invoice lewat email belum diaktifkan untuk situs ini. Gunakan Salin Tautan
          Publik.
        </p>,
      );
    }
    actions.push(<LinkExpiryForm key="expiry" invoiceId={invoiceId} />);
    actions.push(<RevokeLinkForm key="revoke" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canCorrect) {
    actions.push(<CorrectForm key="correct" invoiceId={invoiceId} />);
  }
  if (status === "issued" && permissions.canVoid) {
    actions.push(<VoidForm key="void" invoiceId={invoiceId} />);
  }
  if (status === "draft" && permissions.canCancelDraft) {
    actions.push(<CancelDraftForm key="cancel-draft" invoiceId={invoiceId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
