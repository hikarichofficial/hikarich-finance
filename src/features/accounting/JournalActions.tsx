"use client";

import { useActionState, useState, type ReactNode } from "react";
import {
  discardJournalAction,
  idleJournalActionState,
  postJournalAction,
  reverseJournalAction,
} from "./actions";

/**
 * Journal Detail's status actions (Step 09 §14), following the exact shape `TransferActions.tsx` already
 * established: one small form per action, `useActionState` for error display. Only a `manual`/`adjusting`
 * journal ever reaches these -- `post_journal`/`reverse_journal`/`discard_journal_draft` themselves refuse
 * every other `entry_type` ("system journals are posted by their source workflow"), so `JournalActions`'s own
 * gate (below) mirrors that exactly rather than guessing from the generic workflow shape (decision 162's
 * precedent).
 */

function PostForm({ journalId }: { journalId: string }) {
  const [state, action, pending] = useActionState(postJournalAction, idleJournalActionState);
  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="journal_id" value={journalId} />
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Memposting…" : "Posting Jurnal"}
      </button>
    </form>
  );
}

function DiscardForm({ journalId, entity }: { journalId: string; entity: string | undefined }) {
  const [state, action, pending] = useActionState(discardJournalAction, idleJournalActionState);
  const [open, setOpen] = useState(false);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Buang Draf
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="journal_id" value={journalId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      <p className="hint">
        Draf jurnal ini dihapus permanen tanpa dampak akuntansi. Tidak dapat diurungkan.
      </p>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Membuang…" : "Buang Draf"}
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

function ReverseForm({ journalId }: { journalId: string }) {
  const [state, action, pending] = useActionState(reverseJournalAction, idleJournalActionState);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const today = new Date().toISOString().slice(0, 10);

  if (!open) {
    return (
      <button type="button" className="btn-secondary" onClick={() => setOpen(true)}>
        Balik Jurnal (Reverse)
      </button>
    );
  }

  return (
    <form action={action} className="invoice-action-form">
      <input type="hidden" name="journal_id" value={journalId} />
      <p className="hint">
        Jurnal yang sudah diposting akan dibalik dengan jurnal pembalik. Tidak dapat diurungkan.
      </p>
      <label>
        Tanggal Pembalikan
        <input type="date" name="reversal_date" defaultValue={today} required />
      </label>
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
          {pending ? "Membalik…" : "Balik Jurnal"}
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

export interface JournalActionPermissions {
  canPost: boolean;
  canDiscard: boolean;
  canReverse: boolean;
}

export function JournalActions({
  journalId,
  status,
  entryType,
  entity,
  permissions,
}: {
  journalId: string;
  status: "draft" | "posted";
  entryType: "system" | "manual" | "adjusting" | "reversal" | "opening" | "closing";
  entity: string | undefined;
  permissions: JournalActionPermissions;
}) {
  const editable = entryType === "manual" || entryType === "adjusting";
  if (!editable) return null;

  const actions: ReactNode[] = [];
  if (status === "draft" && permissions.canPost) {
    actions.push(<PostForm key="post" journalId={journalId} />);
  }
  if (status === "draft" && permissions.canDiscard) {
    actions.push(<DiscardForm key="discard" journalId={journalId} entity={entity} />);
  }
  if (status === "posted" && permissions.canReverse) {
    actions.push(<ReverseForm key="reverse" journalId={journalId} />);
  }
  if (actions.length === 0) return null;
  return <div className="invoice-actions">{actions}</div>;
}
