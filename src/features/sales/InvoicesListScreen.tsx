import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { INVOICE_FILTER_OPTIONS, invoicePositionStatus } from "@/domain/sales/invoiceList";
import type { InvoiceFilter, InvoicePosition } from "@/schemas/sales";
import { formatShortDate } from "./format";

/**
 * Invoices List (P13 Part 3a, Step 09 §9, §11): header, filter-tab toolbar, table and empty state. Search
 * is a plain GET form (`?q=`) filtering the rows the page already fetched -- there is no server-side
 * free-text index yet (Global Search is Part 4, DECISIONS 145) -- so it round-trips like every other filter
 * here rather than adding client JS ahead of that index existing. Quick Preview (a side drawer), saved
 * views, export and bulk actions are deferred to a later Part 3a increment (recorded in DECISIONS/TASK_BOARD
 * rather than silently dropped); "Create" already routes through the catch-all placeholder (DECISIONS 157)
 * since the invoice builder itself is that same later increment.
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
        </div>
      ) : (
        <table className="record-table">
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
                    <Link href={href}>{row.invoice_number ?? "Draf"}</Link>
                  </td>
                  <td>{row.customer_name}</td>
                  <td>{formatShortDate(row.issue_date)}</td>
                  <td>{formatShortDate(row.due_date)}</td>
                  <td>
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td className="num">{formatMoney(row.total, row.currency)}</td>
                  <td className="num">{formatMoney(row.outstanding, row.currency)}</td>
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
