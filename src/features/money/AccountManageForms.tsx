"use client";

import { useActionState, useState } from "react";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { deleteAccountAction, setAccountActiveAction } from "./accountActions";
import { idleAccountActionState } from "./accountActionsState";

function Feedback({ state }: { state: { status: string; message?: string } }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}
    </p>
  );
}

/**
 * Hapus Rekening (OWNER, 5 October 2026), behind a double confirmation: step one asks for the account name to be
 * typed exactly, step two repeats what will happen and needs a final tick. An account that already has
 * transactions is allowed too: it leaves every list and picker, while its history and the books stay intact.
 */
export function DeleteAccountForm({
  entity,
  accountId,
  accountName,
  hasHistory,
  balanceText,
}: {
  entity: string | undefined;
  accountId: string;
  accountName: string;
  hasHistory: boolean;
  /** The balance as shown on the screen, for the warning. */
  balanceText: string;
}) {
  const [state, action, pending] = useActionState(deleteAccountAction, idleAccountActionState);
  const actionForm = usePreservingForm(action, state);
  const [typed, setTyped] = useState("");
  const [step, setStep] = useState<1 | 2>(1);
  const nameMatches = typed.trim() === accountName;
  return (
    <details className="account-danger">
      <summary className="btn-danger">Hapus Rekening</summary>
      <form {...actionForm} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="account_id" value={accountId} />
        <input type="hidden" name="expected_name" value={accountName} />
        {hasHistory ? (
          <p>
            Rekening <strong>{accountName}</strong> sudah punya transaksi. Setelah dihapus, rekening
            ini hilang dari semua daftar dan pilihan, tetapi riwayat transaksi dan jurnalnya tetap
            tersimpan agar laporan keuangan tidak berubah. Saldo saat ini:{" "}
            <strong>{balanceText}</strong>. Saldo itu tetap tercatat di buku besar.
          </p>
        ) : (
          <p>
            Rekening <strong>{accountName}</strong> belum punya transaksi, sehingga akan dihapus
            permanen.
          </p>
        )}
        <label>
          Alasan (opsional)
          <input name="reason" maxLength={200} placeholder="mis. salah input / rekening ditutup" />
        </label>
        <label>
          Langkah 1. Ketik nama rekening persis seperti ini: <strong>{accountName}</strong>
          <input
            name="confirm_name"
            value={typed}
            onChange={(event) => {
              setTyped(event.target.value);
              setStep(1);
            }}
            autoComplete="off"
          />
        </label>
        {step === 1 ? (
          <button
            type="button"
            className="btn-danger"
            disabled={!nameMatches}
            onClick={() => setStep(2)}
          >
            Lanjut ke konfirmasi akhir
          </button>
        ) : (
          <>
            <p role="alert" className="error">
              Langkah 2. Ini konfirmasi terakhir. Rekening <strong>{accountName}</strong> akan
              {hasHistory ? " disembunyikan dari semua daftar." : " dihapus permanen."}
            </p>
            <label className="checkbox-field">
              <input type="checkbox" name="confirm" value="yes" required /> Ya, saya yakin dan hapus
              rekening ini
            </label>
            <Feedback state={state} />
            <button type="submit" className="btn-danger" disabled={pending || !nameMatches}>
              {pending ? "Menghapus…" : "Hapus Rekening Sekarang"}
            </button>
          </>
        )}
        {step === 1 ? <Feedback state={state} /> : null}
      </form>
    </details>
  );
}

/** Nonaktifkan / aktifkan kembali -- the way to retire an account that already has transactions. */
export function ToggleAccountActiveForm({
  entity,
  accountId,
  isActive,
}: {
  entity: string | undefined;
  accountId: string;
  isActive: boolean;
}) {
  const [state, action, pending] = useActionState(setAccountActiveAction, idleAccountActionState);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="account_id" value={accountId} />
      <input type="hidden" name="active" value={isActive ? "false" : "true"} />
      {isActive ? (
        <label>
          Alasan menonaktifkan
          <input
            name="reason"
            required
            minLength={5}
            maxLength={200}
            placeholder="mis. rekening ditutup"
          />
        </label>
      ) : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "…" : isActive ? "Nonaktifkan Rekening" : "Aktifkan Kembali"}
      </button>
      <Feedback state={state} />
    </form>
  );
}
