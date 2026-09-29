import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { INVOICE_FILTER_OPTIONS, invoicePositionStatus } from "@/domain/sales/invoiceList";
import type { InvoiceFilter, InvoicePosition } from "@/schemas/sales";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Invoices List (P13 Part 3a, Step 09 §9, §11): header, filter-tab toolbar, table and empty state. Search
 * is a plain GET form (`?q=`) filtering the rows the page already fetched -- there is no server-side
 * free-text index yet for this screen's own filter box (that stays a round trip like every other filter
 * here; Global Search itself is now wired at the Command Menu, P13 Part 6, decision 215). Quick Preview (a
 * side drawer) is wired in this increment (P13 Part 6, decision 215's retrofit) via `RecordPreviewLink` --
 * zero-network, every field shown is already in `row`; saved views, export and bulk actions stay deferred.
 * "Create" already routes through the catch-all placeholder (DECISIONS 157) since the invoice builder
 * itself is a later increment. The empty state carries one CTA (Step 09 §9/§25, Step 10 §24, decision 218):
 * "Hapus Saringan" when a search/filter produced zero rows, else the same "Buat Faktur" action the header
 * already offers when `canCreate` -- never both, and never a guessed-at action neither the header nor the
 * URL already provides.
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5,
 * third increment; Step 09 §23: "dense tables convert to cards/stacked rows with key fields," explicitly
 * naming invoice viewing as a mobile-priority flow) rather than the plain `overflow-x: auto` every other
 * `.record-table` still falls back to -- this is the first screen in a module-by-module rollout, not a
 * blanket change, since Reports' statement viewer and other genuinely columnar `.record-table` usages are
 * deliberately excluded (§23's own carve-out keeps "advanced report building" desktop-optimized).
 */

function buildHref(entity: string | undefined, filter: InvoiceFilter | null, q: string): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("status", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/sales/invoices?${qs}` : "/sales/invoices";
}

export function InvoicesListScreen({
  rows,
  activeFilter,
  query,
  entity,
  canCreate,
}: {
  rows: readonly InvoicePosition[];
  activeFilter: InvoiceFilter | null;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Faktur Penjualan</h1>
          <p className="list-screen-summary">
            {rows.length} faktur{" "}
            {activeFilter ? `pada tampilan "${filterLabel(activeFilter)}"` : "ditampilkan"}.
          </p>
        </div>
        {canCreate ? (
          <Link href="/sales/invoices/new" className="btn-primary">
            Buat Faktur
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status faktur">
          {INVOICE_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(entity, option.value, query)}
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
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          {activeFilter ? <input type="hidden" name="status" value={activeFilter} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor faktur atau nama pelanggan…"
            aria-label="Cari faktur"
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
              ? "Tidak ada faktur yang cocok dengan pencarian ini."
              : "Belum ada faktur pada tampilan ini."}
          </p>
          {query.trim() || activeFilter ? (
            <Link href={buildHref(entity, null, "")} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : canCreate ? (
            <Link href="/sales/invoices/new" className="btn-primary list-empty-action">
              Buat Faktur
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">No. Faktur</th>
              <th scope="col">Pelanggan</th>
              <th scope="col">Tanggal</th>
              <th scope="col">Jatuh Tempo</th>
              <th scope="col">Status</th>
              <th scope="col" className="num">
                Total
              </th>
              <th scope="col" className="num">
                Sisa Tagihan
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = invoicePositionStatus(row);
              const href = entity
                ? `/sales/invoices/${row.invoice_id}?entity=${encodeURIComponent(entity)}`
                : `/sales/invoices/${row.invoice_id}`;
              return (
                <tr key={row.invoice_id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.invoice_number ?? "Draf"}
                      eyebrow="Faktur Penjualan"
                      title={row.invoice_number ?? "Draf"}
                      badges={[{ tone: status.tone, text: status.text }]}
                      fields={[
                        { label: "Pelanggan", value: row.customer_name },
                        { label: "Tanggal", value: formatShortDate(row.issue_date) },
                        { label: "Jatuh Tempo", value: formatShortDate(row.due_date) },
                        { label: "Total", value: formatMoney(row.total, row.currency) },
                        {
                          label: "Sisa Tagihan",
                          value: formatMoney(row.outstanding, row.currency),
                        },
                      ]}
                    />
                  </td>
                  <td data-label="Pelanggan">{row.customer_name}</td>
                  <td data-label="Tanggal">{formatShortDate(row.issue_date)}</td>
                  <td data-label="Jatuh Tempo">{formatShortDate(row.due_date)}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td className="num" data-label="Total">
                    {formatMoney(row.total, row.currency)}
                  </td>
                  <td className="num" data-label="Sisa Tagihan">
                    {formatMoney(row.outstanding, row.currency)}
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

function filterLabel(filter: InvoiceFilter): string {
  return INVOICE_FILTER_OPTIONS.find((option) => option.value === filter)?.label ?? filter;
}
