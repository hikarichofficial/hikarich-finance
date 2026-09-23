import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  BILL_FILTER_OPTIONS,
  billListStatus,
  type BillListFilter,
  type BillListRow,
} from "@/domain/purchases/billList";
import { formatShortDate } from "./format";

/**
 * Bills List (P13 Part 3b, Step 09 §9, §12): header, filter-tab toolbar, table and empty state -- the exact
 * structure `src/features/sales/InvoicesListScreen.tsx` established in Part 3a, with the Bills-specific
 * filter set (`BILL_FILTER_OPTIONS`) and status badge (`billListStatus`) from `billList.ts`. Search is a
 * plain GET form filtering the rows the page already fetched, same rationale as Sales (no server-side
 * free-text index yet; Global Search is Part 4, DECISIONS 145). "Record Bill" is deferred to a later
 * increment (DECISIONS, P13 Part 3b scope) and routes through the catch-all placeholder (DECISIONS 157) for
 * now, same as Sales' "Buat Faktur".
 */

function buildHref(
  entity: string | undefined,
  filter: BillListFilter | null,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("status", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/purchases/bills?${qs}` : "/purchases/bills";
}

export function BillsListScreen({
  rows,
  activeFilter,
  query,
  entity,
  canCreate,
}: {
  rows: readonly BillListRow[];
  activeFilter: BillListFilter | null;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Tagihan Pembelian</h1>
          <p className="list-screen-summary">
            {rows.length} tagihan{" "}
            {activeFilter
              ? `pada tampilan "${filterLabel(activeFilter)}"`
              : "ditampilkan"}
            .
          </p>
        </div>
        {canCreate ? (
          <Link href="/purchases/bills/new" className="btn-primary">
            Catat Tagihan
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status tagihan">
          {BILL_FILTER_OPTIONS.map((option) => (
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
          {activeFilter ? (
            <input type="hidden" name="status" value={activeFilter} />
          ) : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor tagihan atau nama vendor…"
            aria-label="Cari tagihan"
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
              ? "Tidak ada tagihan yang cocok dengan pencarian ini."
              : "Belum ada tagihan pada tampilan ini."}
          </p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">No. Tagihan</th>
              <th scope="col">Vendor</th>
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
              const status = billListStatus(row);
              const href = entity
                ? `/purchases/bills/${row.bill_id}?entity=${encodeURIComponent(entity)}`
                : `/purchases/bills/${row.bill_id}`;
              return (
                <tr key={row.bill_id}>
                  <td>
                    <Link href={href}>{row.bill_number ?? "Draf"}</Link>
                  </td>
                  <td>{row.vendor_name}</td>
                  <td>{formatShortDate(row.bill_date)}</td>
                  <td>{formatShortDate(row.due_date)}</td>
                  <td>
                    <span
                      className={`status-badge status-badge-${status.tone}`}
                    >
                      {status.text}
                    </span>
                  </td>
                  <td className="num">
                    {formatMoney(row.total, row.currency)}
                  </td>
                  <td className="num">
                    {row.outstanding !== null
                      ? formatMoney(row.outstanding, row.currency)
                      : "—"}
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

function filterLabel(filter: BillListFilter): string {
  return (
    BILL_FILTER_OPTIONS.find((option) => option.value === filter)?.label ??
    filter
  );
}
