"use client";

import { useActionState } from "react";
import {
  addLinesAction,
  completeSessionAction,
  createSessionAction,
  discardSessionAction,
  excludeLineAction,
  idleReconActionState,
  includeLineAction,
  matchLineAction,
  reopenSessionAction,
  unmatchLineAction,
  type ReconActionState,
} from "./reconciliationActions";

/** Forms of the reconciliation workspace (decision 251). */

function Result({ state }: { state: ReconActionState }) {
  if (state.status === "idle") return null;
  return (
    <div role={state.status === "error" ? "alert" : "status"}>
      <p className={state.status === "error" ? "error" : "hint"}>{state.message}</p>
      {state.errors && state.errors.length > 0 ? (
        <ul className="error">
          {state.errors.map((e) => (
            <li key={e}>{e}</li>
          ))}
        </ul>
      ) : null}
    </div>
  );
}

function Hidden({ sessionId, entity }: { sessionId: string; entity: string | undefined }) {
  return (
    <>
      <input type="hidden" name="session_id" value={sessionId} />
      <input type="hidden" name="entity" value={entity ?? ""} />
    </>
  );
}

export function NewSessionForm({
  entity,
  accountId,
  accountName,
  currency,
  defaults,
}: {
  entity: string | undefined;
  accountId: string;
  accountName: string;
  currency: string;
  defaults: { periodStart: string; periodEnd: string; opening: string };
}) {
  const [state, action, pending] = useActionState(createSessionAction, idleReconActionState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="account_id" value={accountId} />
      <p className="hint">
        Akun: <strong>{accountName}</strong> ({currency}). Isi periode dan saldo sesuai rekening koran.
      </p>
      <label>
        Periode mulai
        <input type="date" name="period_start" defaultValue={defaults.periodStart} required />
      </label>
      <label>
        Periode akhir
        <input type="date" name="period_end" defaultValue={defaults.periodEnd} required />
      </label>
      <label>
        Saldo awal rekening koran
        <input
          name="statement_opening"
          defaultValue={defaults.opening}
          inputMode="decimal"
          placeholder="contoh 1500000.00"
          required
        />
      </label>
      <label>
        Saldo akhir rekening koran
        <input name="statement_closing" inputMode="decimal" placeholder="contoh 1750000.00" required />
      </label>
      <label>
        Catatan
        <input name="note" maxLength={500} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Membuat…" : "Mulai rekonsiliasi"}
        </button>
      </div>
      <Result state={state} />
    </form>
  );
}

export function AddLinesForm({
  sessionId,
  entity,
}: {
  sessionId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(addLinesAction, idleReconActionState);
  return (
    <form action={action} className="record-form">
      <Hidden sessionId={sessionId} entity={entity} />
      <label>
        Tempel mutasi rekening koran (satu baris per transaksi)
        <textarea
          name="lines"
          rows={6}
          spellCheck={false}
          placeholder={"2026-09-05;-25000;Biaya admin;ADM01\n2026-09-06;1500000;Transfer masuk"}
          required
        />
      </label>
      <p className="hint">
        Format: tanggal;jumlah;keterangan;referensi (pemisah titik koma atau tab). Uang masuk positif,
        uang keluar negatif, titik sebagai desimal. Baris yang sudah pernah ditambahkan dilewati.
      </p>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menambahkan…" : "Tambah baris"}
        </button>
      </div>
      <Result state={state} />
    </form>
  );
}

export function MatchForm({
  sessionId,
  entity,
  lineId,
  candidates,
}: {
  sessionId: string;
  entity: string | undefined;
  lineId: string;
  candidates: ReadonlyArray<{ id: string; label: string }>;
}) {
  const [state, action, pending] = useActionState(matchLineAction, idleReconActionState);
  return (
    <form action={action} className="record-form">
      <Hidden sessionId={sessionId} entity={entity} />
      <input type="hidden" name="line_id" value={lineId} />
      {candidates.length === 0 ? (
        <p className="hint">Tidak ada pergerakan kas yang cocok untuk baris ini.</p>
      ) : (
        <fieldset>
          <legend>Pilih pergerakan kas (totalnya harus sama dengan baris)</legend>
          {candidates.map((c) => (
            <label key={c.id} className="checkbox-field">
              <input type="checkbox" name="movement_id" value={c.id} />
              {c.label}
            </label>
          ))}
        </fieldset>
      )}
      <label>
        Alasan pencocokan manual (bila tanggal/jumlah tidak persis)
        <input name="manual_reason" maxLength={500} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending || candidates.length === 0}>
          {pending ? "Mencocokkan…" : "Cocokkan"}
        </button>
      </div>
      <Result state={state} />
    </form>
  );
}

export function LineReasonForm({
  sessionId,
  entity,
  lineId,
  kind,
}: {
  sessionId: string;
  entity: string | undefined;
  lineId: string;
  kind: "exclude" | "unmatch";
}) {
  const [state, action, pending] = useActionState(
    kind === "exclude" ? excludeLineAction : unmatchLineAction,
    idleReconActionState,
  );
  if (state.status === "ok") return <Result state={state} />;
  return (
    <details>
      <summary>{kind === "exclude" ? "Kecualikan" : "Batalkan cocok"}</summary>
      <form action={action} className="record-form">
        <Hidden sessionId={sessionId} entity={entity} />
        <input type="hidden" name="line_id" value={lineId} />
        <label>
          Alasan (minimal 5 karakter)
          <input name="reason" required minLength={5} maxLength={500} />
        </label>
        <button type="submit" disabled={pending}>
          {kind === "exclude" ? "Kecualikan baris" : "Batalkan pencocokan"}
        </button>
        <Result state={state} />
      </form>
    </details>
  );
}

export function IncludeLineForm({
  sessionId,
  entity,
  lineId,
}: {
  sessionId: string;
  entity: string | undefined;
  lineId: string;
}) {
  const [state, action, pending] = useActionState(includeLineAction, idleReconActionState);
  if (state.status === "ok") return <Result state={state} />;
  return (
    <form action={action}>
      <Hidden sessionId={sessionId} entity={entity} />
      <input type="hidden" name="line_id" value={lineId} />
      <button type="submit" disabled={pending}>
        Kembalikan
      </button>
      <Result state={state} />
    </form>
  );
}

export function CompleteSessionForm({
  sessionId,
  entity,
}: {
  sessionId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(completeSessionAction, idleReconActionState);
  return (
    <form action={action} className="record-form">
      <Hidden sessionId={sessionId} entity={entity} />
      <label>
        Alasan menerima selisih (wajib bila ada selisih, minimal 10 karakter)
        <input name="accept_reason" maxLength={500} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyelesaikan…" : "Selesaikan rekonsiliasi"}
        </button>
      </div>
      <Result state={state} />
    </form>
  );
}

export function ReopenSessionForm({
  sessionId,
  entity,
}: {
  sessionId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(reopenSessionAction, idleReconActionState);
  return (
    <details>
      <summary>Buka kembali</summary>
      <form action={action} className="record-form">
        <Hidden sessionId={sessionId} entity={entity} />
        <label>
          Alasan (minimal 10 karakter)
          <input name="reason" required minLength={10} maxLength={500} />
        </label>
        <button type="submit" disabled={pending}>
          Buka kembali sesi
        </button>
        <Result state={state} />
      </form>
    </details>
  );
}

export function DiscardSessionForm({
  sessionId,
  entity,
}: {
  sessionId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(discardSessionAction, idleReconActionState);
  return (
    <details>
      <summary>Buang sesi</summary>
      <form action={action} className="record-form">
        <Hidden sessionId={sessionId} entity={entity} />
        <p className="hint">
          Sesi beserta baris mutasi dan pencocokannya dihapus. Pergerakan kas tidak berubah.
        </p>
        <button type="submit" className="btn-danger" disabled={pending}>
          Buang sesi ini
        </button>
        <Result state={state} />
      </form>
    </details>
  );
}
