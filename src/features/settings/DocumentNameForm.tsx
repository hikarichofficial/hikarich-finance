"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import {
  DOCUMENT_NAME_STYLES,
  DOCUMENT_NAME_STYLE_LABELS,
  documentNames,
  type DocumentNameStyle,
} from "@/domain/settings/documentNames";
import { setDocumentNameStyleAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";
import { useState } from "react";

/**
 * Which of the Entity's two names its financial documents are headed with (decision 391). Each choice shows
 * what it would actually print, using this Entity's own names, so the decision is made by looking rather than
 * by reading a label.
 */
export function DocumentNameForm({
  entity,
  legalName,
  brandName,
  style,
  stepUpHref,
}: {
  entity: string | undefined;
  legalName: string;
  brandName: string | null;
  style: DocumentNameStyle;
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(
    setDocumentNameStyleAction,
    idleTimeSettingsState,
  );
  const actionForm = usePreservingForm(action, state);
  const [chosen, setChosen] = useState<DocumentNameStyle>(style);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <p className="hint">
        Nama ini dipakai di slip gaji, invoice, kuitansi dan dokumen keuangan lainnya. Untuk PT,
        dokumen pajak sebaiknya memakai nama resmi. Perubahan memerlukan verifikasi ulang dalam 30
        menit terakhir. <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
      </p>

      <div className="choice-cards">
        {DOCUMENT_NAME_STYLES.map((option) => {
          const preview = documentNames(legalName, brandName, option);
          return (
            <label key={option} className="choice-card" data-selected={chosen === option}>
              <input
                type="radio"
                name="name_style"
                value={option}
                checked={chosen === option}
                onChange={() => setChosen(option)}
              />
              <span>
                <strong>{DOCUMENT_NAME_STYLE_LABELS[option]}</strong>
                <span className="doc-name-preview">
                  <span className="doc-name-primary">{preview.primary || "—"}</span>
                  {preview.secondary ? (
                    <span className="doc-name-secondary">{preview.secondary}</span>
                  ) : null}
                </span>
              </span>
            </label>
          );
        })}
      </div>

      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan"}
        </button>
      </div>

      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
          {state.stepUp ? (
            <>
              {" "}
              <StepUpLink href={stepUpHref}>Verifikasi sekarang</StepUpLink>.
            </>
          ) : null}
        </p>
      ) : null}
    </form>
  );
}
