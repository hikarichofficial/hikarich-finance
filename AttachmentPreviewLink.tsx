"use client";

import { useEffect, useRef, useState } from "react";
import { previewKind } from "@/domain/documents/preview";

/**
 * The name of an attached file as a button: clicking it opens a popup with the file (decision 408) instead of
 * leaving the page. Images and PDFs are shown in the popup; "Cetak / Simpan PDF" prints what is shown (the print
 * dialog of the browser has "Save as PDF"). Other types show only the download. The file comes from this
 * site's own `/documents/view/<id>`, which re-checks the permission on every request.
 */
export function AttachmentPreviewLink({
  documentId,
  fileName,
  mimeType,
}: {
  documentId: string;
  fileName: string;
  mimeType: string;
}) {
  const [open, setOpen] = useState(false);
  const frameRef = useRef<HTMLIFrameElement>(null);
  const kind = previewKind(mimeType);
  const viewUrl = `/documents/view/${documentId}`;
  const downloadUrl = `/documents/download/${documentId}`;

  useEffect(() => {
    if (!open) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key === "Escape") setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  function print() {
    try {
      const frame = frameRef.current?.contentWindow;
      if (!frame) throw new Error("no frame");
      frame.focus();
      frame.print();
    } catch {
      window.open(viewUrl, "_blank", "noopener");
    }
  }

  return (
    <>
      <button type="button" className="link-button" onClick={() => setOpen(true)}>
        {fileName}
      </button>
      {open ? (
        <div
          className="modal-overlay"
          role="presentation"
          onClick={(event) => {
            if (event.target === event.currentTarget) setOpen(false);
          }}
        >
          <div
            className="modal-panel attachment-preview"
            role="dialog"
            aria-modal="true"
            aria-label={`Pratinjau ${fileName}`}
          >
            <h2 className="attachment-preview-title">{fileName}</h2>
            {kind === "none" ? (
              <p className="hint">
                Jenis berkas ini tidak bisa ditampilkan di sini. Gunakan Unduh untuk membukanya.
              </p>
            ) : (
              <iframe
                ref={frameRef}
                src={viewUrl}
                title={`Pratinjau ${fileName}`}
                className="attachment-preview-frame"
              />
            )}
            <div className="modal-actions">
              {kind !== "none" ? (
                <button type="button" className="btn-primary" onClick={print}>
                  Cetak / Simpan PDF
                </button>
              ) : null}
              <a className="btn-secondary" href={downloadUrl} target="_blank" rel="noreferrer">
                Unduh
              </a>
              <button type="button" className="btn-ghost" onClick={() => setOpen(false)}>
                Tutup
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
