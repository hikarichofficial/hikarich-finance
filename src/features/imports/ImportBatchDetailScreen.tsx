import Link from "next/link";
import { translateReason } from "@/domain/authz/translateReason";
import {
  IMPORT_BATCH_STATUS_LABELS,
  IMPORT_BATCH_STATUS_TONE,
  IMPORT_DOMAIN_LABELS,
  IMPORT_ROW_STATUS_FILTER_OPTIONS,
  IMPORT_ROW_STATUS_LABELS,
  IMPORT_ROW_STATUS_TONE,
  IMPORT_TARGET_TYPE_LABELS,
} from "@/domain/imports/imports";
import type { ImportBatchRow, ImportRowRow, ImportRowStatus } from "@/schemas/imports";
import { formatShortDate } from "./format";
import { ImportBatchActions } from "./ImportBatchActions";

/**
 * Import batch Detail (P13 unbuilt-screens backlog, decision 241): the batch header plus its rows, filterable
 * by row status, each with its validation messages -- the "one bad row never aborts the whole batch, it is
 * left inspectable" half of Step 08 §19 finally given a screen. Deliberately does not render a row's
 * `raw_payload`/`mapped_payload`: a contacts import can carry a tax identifier, which decision 225 already
 * keeps off every screen behind a column-level grant, and echoing the raw upload here would quietly route
 * around that. Check again / Apply / Undo are `ImportBatchActions` (decision 275).
 */

function buildHref(
  batchId: string,
  entity: string | undefined,
  status: ImportRowStatus | undefined,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (status) params.set("status", status);
  const qs = params.toString();
  return qs ? `/admin/imports/${batchId}?${qs}` : `/admin/imports/${batchId}`;
}

export function ImportBatchDetailScreen({
  batch,
  rows,
  activeStatus,
  entity,
  backHref,
  validRows,
}: {
  batch: ImportBatchRow;
  rows: readonly ImportRowRow[];
  activeStatus: ImportRowStatus | undefined;
  entity: string | undefined;
  backHref: string;
  /** Rows the database marked valid, whatever filter is shown. */
  validRows: number;
}) {
  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke riwayat impor</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Batch Impor · {IMPORT_DOMAIN_LABELS[batch.domain]}
          </p>
          <h1>{batch.source_file_name ?? "(tanpa nama berkas)"}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${IMPORT_BATCH_STATUS_TONE[batch.status]}`}>
            {IMPORT_BATCH_STATUS_LABELS[batch.status]}
          </span>
          <p className="record-detail-dates">{formatShortDate(batch.created_at)}</p>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Jenis Impor</dt>
            <dd>{IMPORT_DOMAIN_LABELS[batch.domain]}</dd>
          </div>
          <div>
            <dt>Jumlah Baris</dt>
            <dd>{batch.row_count}</dd>
          </div>
          <div>
            <dt>Status Batch</dt>
            <dd>{IMPORT_BATCH_STATUS_LABELS[batch.status]}</dd>
          </div>
        </dl>
      </section>

      <ImportBatchActions batchId={batch.batch_id} status={batch.status} validRows={validRows} />

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Baris</h2>
        </div>
        <div className="list-screen-toolbar">
          <nav className="list-filter-tabs" aria-label="Saring status baris">
            {IMPORT_ROW_STATUS_FILTER_OPTIONS.map((option) => (
              <Link
                key={option.label}
                href={buildHref(batch.batch_id, entity, option.value)}
                className={
                  option.value === activeStatus
                    ? "list-filter-tab list-filter-tab-active"
                    : "list-filter-tab"
                }
              >
                {option.label}
              </Link>
            ))}
          </nav>
        </div>

        {rows.length === 0 ? (
          <div className="list-empty">
            <p>
              {activeStatus
                ? "Tidak ada baris dengan status ini."
                : "Batch ini tidak memiliki baris."}
            </p>
          </div>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col" className="num">
                  No.
                </th>
                <th scope="col">Status</th>
                <th scope="col">Pesan</th>
                <th scope="col">Hasil</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.row_id}>
                  <td className="num" data-label="No.">
                    {row.row_no}
                  </td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${IMPORT_ROW_STATUS_TONE[row.status]}`}
                    >
                      {IMPORT_ROW_STATUS_LABELS[row.status]}
                    </span>
                  </td>
                  <td data-label="Pesan">
                    {row.messages.length === 0 ? (
                      "—"
                    ) : (
                      <ul>
                        {row.messages.map((message, index) => (
                          <li key={index}>{translateReason(message) ?? message}</li>
                        ))}
                      </ul>
                    )}
                  </td>
                  <td data-label="Hasil">
                    {row.target_type ? IMPORT_TARGET_TYPE_LABELS[row.target_type] : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
