"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import type { ManagedDocumentPurposeRow } from "@/schemas/documents";
import { renameDocumentPurposeAction, setDocumentPurposeActiveAction } from "./attachmentActions";
import { idleAttachmentActionState } from "./attachmentActionsState";

/**
 * Managing this Entity's own attachment types (decision 401), the half decision 340 left unbuilt: renaming
 * one, and taking one out of use.
 *
 * A type is never deleted. Taking it out of use only stops the upload form offering it; attachments already
 * filed under it keep reading the way they were filed, which is what a document trail requires. The list
 * therefore shows types out of use too, greyed, with a way to put one back.
 *
 * The four built-in types (invoice vendor, kuitansi, kontrak, lainnya) are not here: they are part of the
 * system, not this Entity's own list.
 */
export function DocumentPurposeManager({
  purposes,
  returnPath,
}: {
  purposes: readonly ManagedDocumentPurposeRow[];
  returnPath: string;
}) {
  const [renameState, renameAction, renamePending] = useActionState(
    renameDocumentPurposeAction,
    idleAttachmentActionState,
  );
  const [activeState, activeActionFn, activePending] = useActionState(
    setDocumentPurposeActiveAction,
    idleAttachmentActionState,
  );
  const renameForm = usePreservingForm(renameAction, renameState);
  const activeForm = usePreservingForm(activeActionFn, activeState);
  const [editing, setEditing] = useState<string | null>(null);
  const [name, setName] = useState("");

  const state = renameState.status !== "idle" ? renameState : activeState;

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Jenis Lampiran Sendiri</h2>
      </div>
      <p className="hint">
        Jenis lampiran yang Anda tambahkan sendiri saat mengunggah berkas. Jenis yang tidak dipakai
        lagi hilang dari pilihan unggah, tetapi lampiran lama tetap tercatat dengan jenis itu.
      </p>

      {purposes.length === 0 ? (
        <p className="dashboard-empty">
          Belum ada jenis lampiran sendiri. Tambahkan dari form unggah lampiran.
        </p>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Status</th>
              <th scope="col">Tindakan</th>
            </tr>
          </thead>
          <tbody>
            {purposes.map((purpose) => (
              <tr key={purpose.id} data-muted={purpose.is_active ? undefined : "true"}>
                <td>
                  {editing === purpose.id ? (
                    <form {...renameForm} className="purpose-edit-form">
                      <input type="hidden" name="purpose_id" value={purpose.id} />
                      <input type="hidden" name="return_path" value={returnPath} />
                      <input
                        type="text"
                        name="name"
                        aria-label="Nama jenis lampiran"
                        required
                        minLength={2}
                        maxLength={60}
                        value={name}
                        onChange={(event) => setName(event.target.value)}
                      />
                      <button type="submit" className="btn-primary" disabled={renamePending}>
                        {renamePending ? "Menyimpan…" : "Simpan"}
                      </button>
                      <button type="button" className="btn-ghost" onClick={() => setEditing(null)}>
                        Batal
                      </button>
                    </form>
                  ) : (
                    purpose.name
                  )}
                </td>
                <td data-label="Status">
                  <span
                    className={`status-badge status-badge-${purpose.is_active ? "success" : "neutral"}`}
                  >
                    {purpose.is_active ? "Dipakai" : "Tidak dipakai"}
                  </span>
                </td>
                <td data-label="Tindakan">
                  {editing === purpose.id ? null : (
                    <span className="purpose-actions">
                      <button
                        type="button"
                        className="btn-ghost"
                        onClick={() => {
                          setEditing(purpose.id);
                          setName(purpose.name);
                        }}
                      >
                        Ubah nama
                      </button>
                      <form {...activeForm} className="purpose-actions">
                        <input type="hidden" name="purpose_id" value={purpose.id} />
                        <input type="hidden" name="return_path" value={returnPath} />
                        <input
                          type="hidden"
                          name="active"
                          value={purpose.is_active ? "false" : "true"}
                        />
                        <button type="submit" className="btn-ghost" disabled={activePending}>
                          {purpose.is_active ? "Tidak dipakai lagi" : "Pakai lagi"}
                        </button>
                      </form>
                    </span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
        </p>
      ) : null}
    </section>
  );
}
