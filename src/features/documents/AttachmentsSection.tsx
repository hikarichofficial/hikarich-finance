import { documentPurposeLabel, formatDocumentSize } from "@/domain/documents/documents";
import type { GenericLinkableTargetType } from "@/schemas/documents";
import { listDocumentLinks, listDocumentPurposes } from "@/services/documents/documents";
import { documentStorageEnabled } from "@/services/documents/storage";
import { AttachmentRemoveForm, AttachmentUploadForm } from "./AttachmentForms";

/**
 * "Lampiran" on a record's detail page (Step 08 §21, decision 275): the files linked to this record, a
 * download link each, and the upload form. `list_document_links` checks that the person may see the record;
 * the download route re-checks per file; whether a file may still be added or removed in the record's
 * current status is the database's answer when the form is sent.
 */
export async function AttachmentsSection({
  entityId,
  entity,
  targetType,
  targetId,
  returnPath,
  canUpload,
  defaultPurpose = "other",
  embedded = false,
}: {
  entityId: string;
  entity: string | undefined;
  targetType: GenericLinkableTargetType;
  targetId: string;
  returnPath: string;
  canUpload: boolean;
  defaultPurpose?: "vendor_invoice" | "receipt" | "contract" | "other";
  /** Shown inside the record's own "Dokumen" section (decision 332) instead of as a card of its own. */
  embedded?: boolean;
}) {
  const [links, customPurposes] = await Promise.all([
    listDocumentLinks({
      entity_id: entityId,
      target_type: targetType,
      target_id: targetId,
    }).catch(() => null),
    listDocumentPurposes(entityId).catch(() => []),
  ]);
  if (links === null) return null;
  const customNames = new Map(customPurposes.map((p) => [p.id, p.name]));
  const storageOn = documentStorageEnabled();

  const Wrapper = embedded ? "div" : "section";
  return (
    <Wrapper className={embedded ? "attachments-embedded" : "dashboard-section"}>
      {embedded ? (
        <h3 className="attachments-embedded-title">Lampiran</h3>
      ) : (
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Lampiran</h2>
        </div>
      )}
      {links.length === 0 ? (
        <p className="hint">Belum ada lampiran.</p>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Berkas</th>
              <th scope="col">Jenis</th>
              <th scope="col" className="num">
                Ukuran
              </th>
              <th scope="col">Tindakan</th>
            </tr>
          </thead>
          <tbody>
            {links.map((link) => (
              <tr key={link.link_id}>
                <td data-label="Berkas">
                  <a
                    href={`/documents/download/${link.document_id}`}
                    target="_blank"
                    rel="noreferrer"
                  >
                    {link.file_name}
                  </a>
                </td>
                <td data-label="Jenis">{documentPurposeLabel(link.purpose, customNames)}</td>
                <td className="num" data-label="Ukuran">
                  {formatDocumentSize(link.size_bytes)}
                </td>
                <td data-label="Tindakan">
                  {canUpload ? (
                    <AttachmentRemoveForm linkId={link.link_id} returnPath={returnPath} />
                  ) : (
                    "—"
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
      {!canUpload ? null : storageOn ? (
        <AttachmentUploadForm
          entity={entity}
          targetType={targetType}
          targetId={targetId}
          returnPath={returnPath}
          defaultPurpose={defaultPurpose}
          customPurposes={customPurposes}
        />
      ) : (
        <p className="hint">Penyimpanan berkas belum diaktifkan untuk situs ini.</p>
      )}
    </Wrapper>
  );
}
