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
import { Picker } from "@/features/shared/Picker";
import {
  createDocumentPurposeAction,
  deleteAttachmentAction,
  deleteDocumentAction,
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
  // The built-in types first, then the Entity's own -- the order the dropdown had, which the Picker keeps
  // while nothing is typed (decision 406).
  const purposeItems = [
    ...builtinDocumentPurposeSchema.options.map((option) => ({
      id: option,
      label: DOCUMENT_PURPOSE_LABELS[option],
    })),
    ...allCustom.map((custom) => ({
      id: `${CUSTOM_PURPOSE_PREFIX}${custom.id}`,
      label: custom.name,
    })),
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
      <Picker
        label="Jenis lampiran"
        name="purpose"
        noun="jenis lampiran"
        items={purposeItems}
        value={purpose}
        onChange={setPurpose}
        onAddNew={(typed) => {
          setNewName(typed);
          setAdding(true);
        }}
      />
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

/**
 * Delete an attachment for good, in every menu (decision 418). Two steps: the "Hapus" button opens a short form with a
 * reason and a tick that says the file is deleted for good; only then the delete button works. The database records who
 * deleted it, when and why.
 */
export function AttachmentDeleteForm({
  linkId,
  documentId,
  returnPath,
}: {
  /** Delete the attachment of one record (the link). */
  linkId?: string;
  /** Or delete a whole file with every link it has (the Documents screens). */
  documentId?: string;
  returnPath: string;
}) {
  const [state, action, pending] = useActionState(
    linkId ? deleteAttachmentAction : deleteDocumentAction,
    idleAttachmentActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [sure, setSure] = useState(false);
  return (
    <details>
      <summary className="danger-link">Hapus</summary>
      <form {...actionForm} className="record-form">
        {linkId ? <input type="hidden" name="link_id" value={linkId} /> : null}
        {documentId ? <input type="hidden" name="document_id" value={documentId} /> : null}
        <input type="hidden" name="return_path" value={returnPath} />
        <input type="hidden" name="confirm" value={sure ? "yes" : "no"} />
        <label>
          Alasan
          <input name="reason" required minLength={3} maxLength={1000} />
        </label>
        <label className="check-line">
          <input
            type="checkbox"
            checked={sure}
            onChange={(event) => setSure(event.target.checked)}
          />
          Saya paham berkas ini dihapus permanen dan tidak bisa dikembalikan.
        </label>
        <p className="hint">
          Catatan siapa yang menghapus, kapan, dan alasannya tetap tersimpan di jejak audit.
        </p>
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}
        <button type="submit" className="btn-danger" disabled={pending || !sure}>
          {pending ? "Menghapus…" : "Hapus Permanen"}
        </button>
      </form>
    </details>
  );
}
