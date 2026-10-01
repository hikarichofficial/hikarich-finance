"use client";

import { useActionState } from "react";
import {
  deleteSavedReportAction,
  idleSavedReportState,
  saveReportAction,
  type SavedReportState,
} from "./savedReportActions";

function Result({ state }: { state: SavedReportState }) {
  if (state.status === "idle") return null;
  return (
    <p
      role={state.status === "error" ? "alert" : "status"}
      className={state.status === "error" ? "error" : "hint"}
    >
      {state.message}
    </p>
  );
}

/** "Simpan laporan ini": keeps the current report page and its filters under a name (decision 252). */
export function SaveReportForm({
  entity,
  path,
  query,
}: {
  entity: string | undefined;
  path: string;
  query: string;
}) {
  const [state, action, pending] = useActionState(saveReportAction, idleSavedReportState);
  return (
    <details className="dashboard-section">
      <summary>Simpan laporan ini</summary>
      <form action={action} className="record-form">
        <input type="hidden" name="entity" value={entity ?? ""} />
        <input type="hidden" name="path" value={path} />
        <input type="hidden" name="query" value={query} />
        <label>
          Nama laporan
          <input name="name" required minLength={2} maxLength={120} />
        </label>
        <button type="submit" className="btn-secondary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan"}
        </button>
        <Result state={state} />
      </form>
    </details>
  );
}

export function DeleteSavedReportForm({ id }: { id: string }) {
  const [state, action, pending] = useActionState(deleteSavedReportAction, idleSavedReportState);
  if (state.status === "ok") return <Result state={state} />;
  return (
    <form action={action}>
      <input type="hidden" name="id" value={id} />
      <button type="submit" disabled={pending}>
        Hapus
      </button>
      <Result state={state} />
    </form>
  );
}
