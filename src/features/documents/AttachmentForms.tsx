"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { ATTACHMENT_ACCEPT } from "@/domain/documents/fileSignature";
import { DOCUMENT_PURPOSE_LABELS } from "@/domain/documents/documents";
import {
  builtinDocumentPurposeSchema,
  CUSTOM_PURPOSE_PREFIX,
  type DocumentPurposeRow,
  type GenericLinkableTargetType,
} from "@/schemas/documents";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import {
  createDocumentPurposeAction,
  removeAttachmentAction,
  uploadAttachmentAction,
} from "./attachmentActions";
import { idleAttachmentActionState } from "./attachmentActionsState";

export function AttachmentUploadForm({
  entity,
  targetType,
  targetId,
  returnPath,
  defaultPurpose,
  customPurposes = [],
}: {
  /** The types this Entity added itself, offered after the built-in ones. */
  customPurposes?: readonly DocumentPurposeRow[];
  entity: string | undefined;
  targetType: GenericLinkableTargetType;
  targetId: string;
  returnPath: string;
  defaultPurpose: string;
}) {
  const [state, action, pending] = useActionState(
    uploadAttachmentAction,
    idleAttachmentActionState,
  );
  const actionForm = usePreservingForm(action, state);
  // A type added here is chosen at once, before the page itself refreshes.
  const [added, setAdded] = useState<DocumentPurposeRow[]>([]);
  const [purpose, setPurpose] = useState(defaultPurpose);
  const [adding, setAdding] = useState(false);
  const [newName, setNewName] = useState("");
  const [addError, setAddError] = useState<string | null>(null);
  const [savingType, setSavingType] = useState(false);
  const allCustom = [
    ...customPurposes,
    ...added.filter((a) => !customPurposes.some((c) => c.id === a.id)),
  ];

  async function saveType() {
    setSavingType(true);
    setAddError(null);
    const result = await createDocumentPurposeAction(entity ?? "", newName);
    setSavingType(false);
    if (result.status === "error") {
      setAddError(result.message);
      return;
    }
    setAdded((list) => [...list, result.purpose]);
    setPurpose(`${CUSTOM_PURPOSE_PREFIX}${result.purpose.id}`);
    setAdding(false);
    setNewName("");
  }

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="target_type" value={targetType} />
      <input type="hidden" name="target_id" value={targetId} />
      <input type="hidden" name="return_path" value={returnPath} />
      <label>
        Berkas (PDF, JPG, PNG atau WebP, maksimal 4 MB)
        <input type="file" name="file" accept={ATTACHMENT_ACCEPT} required />
      </label>
      <label>
        Jenis lampiran
        <select
          name="purpose"
          value={purpose}
          onChange={(event) => {
            if (event.target.value === "__add__") {
              setAdding(true);
              return;
            }
            setPurpose(event.target.value);
          }}
        >
          {builtinDocumentPurposeSchema.options.map((option) => (
            <option key={option} value={option}>
              {DOCUMENT_PURPOSE_LABELS[option]}
            </option>
          ))}
          {allCustom.map((custom) => (
            <option key={custom.id} value={`${CUSTOM_PURPOSE_PREFIX}${custom.id}`}>
              {custom.name}
            </option>
          ))}
          <option value="__add__">+ Tambah jenis lampiran…</option>
        </select>
      </label>
      {adding ? (
        <div className="attachment-new-type">
          <label>
            Nama jenis lampiran baru
            <input
              value={newName}
              onChange={(event) => setNewName(event.target.value)}
              maxLength={60}
              autoComplete="off"
              placeholder="mis. Surat Jalan"
            />
          </label>
          {addError ? (
            <p role="alert" className="error">
              {addError}
            </p>
          ) : null}
          <div className="attachment-new-type-actions">
            <button
              type="button"
              className="btn-secondary"
              disabled={savingType}
              onClick={saveType}
            >
              {savingType ? "Menyimpan…" : "Simpan Jenis"}
            </button>
            <button
              type="button"
              className="btn-ghost"
              onClick={() => {
                setAdding(false);
                setAddError(null);
              }}
            >
              Batal
            </button>
          </div>
        </div>
      ) : null}
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Mengunggah…" : "Lampirkan"}
      </button>
    </form>
  );
}

export function AttachmentRemoveForm({
  linkId,
  returnPath,
}: {
  linkId: string;
  returnPath: string;
}) {
  const [state, action, pending] = useActionState(
    removeAttachmentAction,
    idleAttachmentActionState,
  );
  const actionForm = usePreservingForm(action, state);
  return (
    <details>
      <summary>Lepas</summary>
      <form {...actionForm} className="record-form">
        <input type="hidden" name="link_id" value={linkId} />
        <input type="hidden" name="return_path" value={returnPath} />
        <label>
          Alasan
          <input name="reason" required minLength={3} maxLength={1000} />
        </label>
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}
        <button type="submit" className="btn-danger" disabled={pending}>
          {pending ? "Melepas…" : "Lepas Lampiran"}
        </button>
      </form>
    </details>
  );
}
