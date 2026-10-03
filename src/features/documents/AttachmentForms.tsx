"use client";

import { useActionState } from "react";
import { ATTACHMENT_ACCEPT } from "@/domain/documents/fileSignature";
import { DOCUMENT_PURPOSE_LABELS } from "@/domain/documents/documents";
import { documentPurposeSchema, type GenericLinkableTargetType } from "@/schemas/documents";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { removeAttachmentAction, uploadAttachmentAction } from "./attachmentActions";
import { idleAttachmentActionState } from "./attachmentActionsState";

export function AttachmentUploadForm({
  entity,
  targetType,
  targetId,
  returnPath,
  defaultPurpose,
}: {
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
        <select name="purpose" defaultValue={defaultPurpose}>
          {documentPurposeSchema.options.map((option) => (
            <option key={option} value={option}>
              {DOCUMENT_PURPOSE_LABELS[option]}
            </option>
          ))}
        </select>
      </label>
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
