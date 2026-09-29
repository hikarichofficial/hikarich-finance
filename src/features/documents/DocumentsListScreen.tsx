import Link from "next/link";
import {
  DOCUMENT_TARGET_TYPE_FILTER_OPTIONS,
  documentTargetTypesLabel,
  formatDocumentSize,
} from "@/domain/documents/documents";
import type { DocumentRow, DocumentTargetType } from "@/schemas/documents";
import { formatShortDate } from "./format";

/**
 * Documents Center listing (P13 Part 4, sixth increment; Step 01 #35, Step 15 §15): header, filter-tab
 * toolbar (by target kind), search-by-name form and table, the exact structure
 * `src/features/purchases/BillsListScreen.tsx` established. Unlike Bills, `list_documents` filters and
 * paginates server-side (`p_target_type`/`p_q`/`p_limit`/`p_offset`), so search and filtering are plain GET
 * params sent straight to the route rather than a client-side filter over an already-fetched list; "Next"
 * appears whenever a full page came back (the RPC returns no total count to check against instead).
 * Upload (`documents.upload`, `registerDocument`/`finalizeDocumentUpload`) and a per-document detail/download
 * view stay deferred -- Storage itself is not yet configured (DECISIONS 142) -- but the nav's own "Uploads"
 * and "Linked Evidence" sub-routes (P13 Part 4, tenth increment, DECISIONS 198) reuse this exact screen: an
 * optional `basePath`/`title`/`showTargetTypeFilter` let `/documents/uploads` and `/documents/evidence` point
 * every link and form at their own route and hide a filter tab that would never match (an unlinked document
 * never has a `target_type` of its own, so filtering the Uploads view by kind would always come back empty --
 * `filterDocumentsByLinkStatus`, `@/domain/documents/documents`). `hasMore` is accepted as a prop rather than
 * always derived from `rows.length` because those two routes filter the fetched page by link status before
 * it reaches this component -- the caller computes it from the RPC's own raw page, so "Berikutnya" keeps
 * reflecting the real `list_documents` windowing even when the displayed row count has shrunk.
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5;
 * Step 09 §23), the same way `BillsListScreen` already does (decision 203) -- Nama Berkas as the unlabelled
 * heading, a plain filename with no drill-down since no per-document detail screen exists yet.
 */

const PAGE_SIZE = 50;

function buildHref(
  basePath: string,
  entity: string | undefined,
  targetType: DocumentTargetType | null,
  q: string,
  offset: number,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (targetType) params.set("target_type", targetType);
  if (q.trim()) params.set("q", q.trim());
  if (offset > 0) params.set("offset", String(offset));
  const qs = params.toString();
  return qs ? `${basePath}?${qs}` : basePath;
}

export function DocumentsListScreen({
  rows,
  activeFilter,
  query,
  entity,
  offset,
  basePath = "/documents",
  title = "Pusat Dokumen",
  showTargetTypeFilter = true,
  hasMore,
}: {
  rows: readonly DocumentRow[];
  activeFilter: DocumentTargetType | null;
  query: string;
  entity: string | undefined;
  offset: number;
  basePath?: string;
  title?: string;
  showTargetTypeFilter?: boolean;
  hasMore?: boolean;
}) {
  const more = hasMore ?? rows.length === PAGE_SIZE;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>{title}</h1>
          <p className="list-screen-summary">
            {rows.length} dokumen{" "}
            {activeFilter ? `pada tampilan "${filterLabel(activeFilter)}"` : "ditampilkan"}.
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        {showTargetTypeFilter ? (
          <nav className="list-filter-tabs" aria-label="Saring jenis dokumen">
            {DOCUMENT_TARGET_TYPE_FILTER_OPTIONS.map((option) => (
              <Link
                key={option.label}
                href={buildHref(basePath, entity, option.value, query, 0)}
                className={
                  option.value === activeFilter
                    ? "list-filter-tab list-filter-tab-active"
                    : "list-filter-tab"
                }
              >
                {option.label}
              </Link>
            ))}
          </nav>
        ) : null}
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          {activeFilter ? <input type="hidden" name="target_type" value={activeFilter} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nama berkas…"
            aria-label="Cari dokumen"
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>
            {query.trim()
              ? "Tidak ada dokumen yang cocok dengan pencarian ini."
              : "Belum ada dokumen pada tampilan ini."}
          </p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama Berkas</th>
              <th scope="col">Terkait Dengan</th>
              <th scope="col" className="num">
                Tautan
              </th>
              <th scope="col" className="num">
                Ukuran
              </th>
              <th scope="col">Diunggah</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.document_id}>
                <td>{row.file_name}</td>
                <td data-label="Terkait Dengan">{documentTargetTypesLabel(row.target_types)}</td>
                <td className="num" data-label="Tautan">
                  {row.link_count}
                </td>
                <td className="num" data-label="Ukuran">
                  {formatDocumentSize(row.size_bytes)}
                </td>
                <td data-label="Diunggah">{formatShortDate(row.created_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {offset > 0 || more ? (
        <div className="list-screen-toolbar" aria-label="Navigasi halaman">
          {offset > 0 ? (
            <Link
              href={buildHref(
                basePath,
                entity,
                activeFilter,
                query,
                Math.max(0, offset - PAGE_SIZE),
              )}
              className="btn-secondary"
            >
              Sebelumnya
            </Link>
          ) : null}
          {more ? (
            <Link
              href={buildHref(basePath, entity, activeFilter, query, offset + PAGE_SIZE)}
              className="btn-secondary"
            >
              Berikutnya
            </Link>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function filterLabel(filter: DocumentTargetType): string {
  return (
    DOCUMENT_TARGET_TYPE_FILTER_OPTIONS.find((option) => option.value === filter)?.label ?? filter
  );
}
