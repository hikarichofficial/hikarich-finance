import Link from "next/link";
import {
  IMPORT_BATCH_STATUS_LABELS,
  IMPORT_BATCH_STATUS_TONE,
  IMPORT_DOMAIN_FILTER_OPTIONS,
  IMPORT_DOMAIN_LABELS,
} from "@/domain/imports/imports";
import type { ImportBatchRow, ImportDomain } from "@/schemas/imports";
import { formatShortDate } from "./format";

/**
 * Import history List (P13 unbuilt-screens backlog, decision 241): every import batch of the active Entity,
 * newest first, filterable by domain. "Impor Data" opens the Import Wizard (decision 275).
 */

function buildHref(entity: string | undefined, domain: ImportDomain | undefined): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (domain) params.set("domain", domain);
  const qs = params.toString();
  return qs ? `/admin/imports?${qs}` : "/admin/imports";
}

export function ImportBatchesListScreen({
  rows,
  activeDomain,
  entity,
}: {
  rows: readonly ImportBatchRow[];
  activeDomain: ImportDomain | undefined;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Riwayat Impor</h1>
          <p className="list-screen-summary">
            {rows.length} batch impor{" "}
            {activeDomain ? `untuk "${IMPORT_DOMAIN_LABELS[activeDomain]}"` : "ditampilkan"}.
          </p>
        </div>
        <Link
          href={
            entity
              ? `/admin/imports/new?entity=${encodeURIComponent(entity)}`
              : "/admin/imports/new"
          }
          className="btn-primary"
        >
          Impor Data
        </Link>
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring jenis impor">
          {IMPORT_DOMAIN_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(entity, option.value)}
              className={
                option.value === activeDomain
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
            {activeDomain
              ? "Tidak ada batch impor untuk jenis ini."
              : "Belum ada batch impor untuk entitas ini."}
          </p>
          {activeDomain ? (
            <Link href={buildHref(entity, undefined)} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Berkas Sumber</th>
              <th scope="col">Jenis</th>
              <th scope="col">Tanggal</th>
              <th scope="col" className="num">
                Baris
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const href = entity
                ? `/admin/imports/${row.batch_id}?entity=${encodeURIComponent(entity)}`
                : `/admin/imports/${row.batch_id}`;
              return (
                <tr key={row.batch_id}>
                  <td>
                    <Link href={href}>{row.source_file_name ?? "(tanpa nama berkas)"}</Link>
                  </td>
                  <td data-label="Jenis">{IMPORT_DOMAIN_LABELS[row.domain]}</td>
                  <td data-label="Tanggal">{formatShortDate(row.created_at)}</td>
                  <td className="num" data-label="Baris">
                    {row.row_count}
                  </td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${IMPORT_BATCH_STATUS_TONE[row.status]}`}
                    >
                      {IMPORT_BATCH_STATUS_LABELS[row.status]}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
