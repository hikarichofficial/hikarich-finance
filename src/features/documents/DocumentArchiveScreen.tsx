import Link from "next/link";
import { documentTargetTypesLabel, formatDocumentSize } from "@/domain/documents/documents";
import type { DocumentArchiveRow } from "@/schemas/documents";
import { formatShortDate } from "./format";

/**
 * Documents Archive (Step 09 §20 "Archive is accessible but visually separated from active evidence",
 * decision 252): documents replaced by a newer version and documents whose links were all removed. Nothing
 * here is active evidence; the replacement version is named where there is one.
 */
export function DocumentArchiveScreen({
  rows,
  query,
  entity,
  offset,
  hasMore,
  pageSize,
}: {
  rows: readonly DocumentArchiveRow[];
  query: string;
  entity: string | undefined;
  offset: number;
  hasMore: boolean;
  pageSize: number;
}) {
  const pageHref = (o: number) => {
    const p = new URLSearchParams();
    if (entity) p.set("entity", entity);
    if (query) p.set("q", query);
    if (o > 0) p.set("offset", String(o));
    const s = p.toString();
    return s ? `/documents/archive?${s}` : "/documents/archive";
  };
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Arsip Dokumen</h1>
          <p className="list-screen-summary">
            Dokumen yang sudah diganti versi baru atau dilepas dari transaksinya. Bukan bukti aktif.
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nama berkas…"
            aria-label="Cari arsip dokumen"
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada dokumen di arsip.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Berkas</th>
              <th scope="col">Alasan Diarsipkan</th>
              <th scope="col">Dulu Terkait</th>
              <th scope="col">Diarsipkan</th>
              <th scope="col" className="num">
                Ukuran
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.document_id}>
                <td>{r.file_name}</td>
                <td data-label="Alasan Diarsipkan">
                  {r.archive_reason === "superseded" ? (
                    <>
                      <span className="status-badge status-badge-neutral">Diganti versi baru</span>
                      {r.superseded_by_name ? ` → ${r.superseded_by_name}` : ""}
                    </>
                  ) : (
                    <>
                      <span className="status-badge status-badge-neutral">Dilepas</span>
                      {r.removed_reason ? ` — ${r.removed_reason}` : ""}
                    </>
                  )}
                </td>
                <td data-label="Dulu Terkait">{documentTargetTypesLabel(r.former_target_types)}</td>
                <td data-label="Diarsipkan">
                  {r.archived_at ? formatShortDate(r.archived_at) : "—"}
                </td>
                <td className="num" data-label="Ukuran">
                  {formatDocumentSize(r.size_bytes)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {offset > 0 || hasMore ? (
        <div className="list-screen-toolbar" aria-label="Navigasi halaman">
          {offset > 0 ? (
            <Link href={pageHref(Math.max(0, offset - pageSize))} className="btn-secondary">
              Sebelumnya
            </Link>
          ) : null}
          {hasMore ? (
            <Link href={pageHref(offset + pageSize)} className="btn-secondary">
              Berikutnya
            </Link>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}
