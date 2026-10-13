import { AttachmentDeleteForm } from "@/features/documents/AttachmentForms";
import { AttachmentPreviewLink } from "@/features/documents/AttachmentPreviewLink";
import { formatDocumentSize } from "@/domain/documents/documents";
import { EVIDENCE_PURPOSE_LABELS } from "@/domain/tax/tax";
import type { TaxEvidenceRow } from "@/schemas/tax";
import { formatShortDate } from "./format";

/** The proofs attached to one tax payment or filing; each opens in the preview (shared by the filing screen and the payment page). */
export function EvidenceList({
  title,
  rows,
  returnPath,
}: {
  title: string | null;
  rows: readonly TaxEvidenceRow[];
  /** The page the delete goes back to (decision 418); without it the proofs are shown without a delete button. */
  returnPath?: string;
}) {
  return (
    <>
      {title ? <p className="hint">Bukti untuk {title}.</p> : null}
      {rows.length === 0 ? (
        <p className="hint">Belum ada bukti terlampir.</p>
      ) : (
        <ul className="dashboard-list">
          {rows.map((e) => (
            <li key={e.link_id} className="dashboard-list-item">
              <p className="dashboard-list-item-title">
                <AttachmentPreviewLink
                  documentId={e.document_id}
                  fileName={e.file_name}
                  mimeType={e.mime_type}
                />
              </p>
              <p className="dashboard-list-item-detail">
                {EVIDENCE_PURPOSE_LABELS[e.purpose]} &middot; {formatDocumentSize(e.size_bytes)}{" "}
                &middot; {formatShortDate(e.created_at.slice(0, 10))}
              </p>
              {returnPath ? <AttachmentDeleteForm linkId={e.link_id} returnPath={returnPath} /> : null}
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
