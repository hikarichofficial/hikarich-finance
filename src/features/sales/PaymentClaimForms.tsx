"use client";

import { useActionState, useState } from "react";
import type { SettlementAccountOption } from "@/features/shared/SettlementForm";
import { confirmClaimAction, markClaimDuplicateAction, rejectClaimAction } from "./actions";
import { idleInvoiceActionState } from "./actionsState";

export interface DuplicateClaimOption {
  id: string;
  label: string;
}

/**
 * Confirm or reject one pending payment claim (decision 259, Step 07 §4). Confirming is where the money is
 * actually recognised: the person picks the account it arrived in and may correct the date or amount to
 * what the bank shows. Rejecting needs a reason and has no financial effect. "Tandai Duplikat" is offered
 * when the same invoice has another pending claim (`mark_submission_duplicate` only accepts a claim of the
 * same invoice); it has no financial effect either.
 */
export function PaymentClaimForms({
  submissionId,
  accounts,
  amount,
  paymentDate,
  otherClaims = [],
}: {
  submissionId: string;
  accounts: readonly SettlementAccountOption[];
  amount: string;
  paymentDate: string;
  /** The other pending claims of the same invoice, for "Tandai Duplikat". */
  otherClaims?: readonly DuplicateClaimOption[];
}) {
  const [confirmState, confirmAction, confirming] = useActionState(
    confirmClaimAction,
    idleInvoiceActionState,
  );
  const [rejectState, rejectAction, rejecting] = useActionState(
    rejectClaimAction,
    idleInvoiceActionState,
  );
  const [duplicateState, duplicateAction, markingDuplicate] = useActionState(
    markClaimDuplicateAction,
    idleInvoiceActionState,
  );
  const [mode, setMode] = useState<"closed" | "confirm" | "reject" | "duplicate">("closed");

  if (mode === "closed") {
    return (
      <div className="invoice-actions">
        <button type="button" className="btn-primary" onClick={() => setMode("confirm")}>
          Konfirmasi
        </button>
        <button type="button" className="btn-secondary" onClick={() => setMode("reject")}>
          Tolak
        </button>
        {otherClaims.length > 0 ? (
          <button type="button" className="btn-ghost" onClick={() => setMode("duplicate")}>
            Tandai Duplikat
          </button>
        ) : null}
      </div>
    );
  }

  if (mode === "duplicate") {
    return (
      <form action={duplicateAction} className="record-form">
        <input type="hidden" name="submission_id" value={submissionId} />
        <label>
          Klaim Ini Sama dengan
          <select name="duplicate_of_id" required defaultValue="">
            <option value="" disabled>
              Pilih klaim lain dari invoice yang sama
            </option>
            {otherClaims.map((claim) => (
              <option key={claim.id} value={claim.id}>
                {claim.label}
              </option>
            ))}
          </select>
        </label>
        <label>
          Alasan (minimal 5 karakter)
          <input name="reason" required minLength={5} maxLength={500} />
        </label>
        {duplicateState.status === "error" ? (
          <p role="alert" className="error">
            {duplicateState.message}
          </p>
        ) : null}
        <button type="submit" className="btn-secondary" disabled={markingDuplicate}>
          {markingDuplicate ? "Menyimpan…" : "Tandai Duplikat"}
        </button>
      </form>
    );
  }

  if (mode === "reject") {
    return (
      <form action={rejectAction} className="record-form">
        <input type="hidden" name="submission_id" value={submissionId} />
        <label>
          Alasan Penolakan (minimal 5 karakter)
          <input name="reason" required minLength={5} maxLength={1000} />
        </label>
        {rejectState.status === "error" ? (
          <p role="alert" className="error">
            {rejectState.message}
          </p>
        ) : null}
        <button type="submit" className="btn-secondary" disabled={rejecting}>
          {rejecting ? "Menyimpan…" : "Tolak Klaim"}
        </button>
      </form>
    );
  }

  return (
    <form action={confirmAction} className="record-form">
      <input type="hidden" name="submission_id" value={submissionId} />
      <label>
        Diterima di Rekening
        <select name="account_id" required defaultValue="">
          <option value="" disabled>
            Pilih rekening kas/bank
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal Uang Masuk
        <input type="date" name="payment_date" required defaultValue={paymentDate} />
      </label>
      <label>
        Jumlah yang Benar-benar Masuk
        <input name="amount" required inputMode="decimal" defaultValue={amount} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} />
      </label>
      {confirmState.status === "error" ? (
        <p role="alert" className="error">
          {confirmState.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={confirming}>
        {confirming ? "Menyimpan…" : "Konfirmasi Pembayaran"}
      </button>
    </form>
  );
}
