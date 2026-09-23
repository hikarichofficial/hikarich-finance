import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  TRANSFER_FILTER_OPTIONS,
  transferListStatus,
  type TransferListFilter,
  type TransferListRow,
} from "@/domain/money/transferList";
import { formatShortDate } from "./format";

/**
 * Transfers List (P13 Part 3c, Step 09 §9, §13), the exact structure `InvoicesListScreen`/`BillsListScreen`
 * already established. Unlike Sales/Purchases, the create action here already routes to a real page
 * (`/money/transfers/new`) rather than the catch-all placeholder -- the Transfer form is small enough that
 * Part 3c builds it alongside List/Detail rather than deferring it (decision 164's own "materially larger"
 * test for when to defer a builder).
 */

function buildHref(
  entity: string | undefined,
  filter: TransferListFilter | null,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("status", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/money/transfers?${qs}` : "/money/transfers";
}

export function TransfersListScreen({
  rows,
  activeFilter,
  query,
  entity,
  canCreate,
}: {
  rows: readonly TransferListRow[];
  activeFilter: TransferListFilter | null;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Transfer Antar Akun</h1>
          <p className="list-screen-summary">
            {rows.length} transfer{" "}
            {activeFilter
              ? `pada tampilan "${filterLabel(activeFilter)}"`
              : "ditampilkan"}
            .
          </p>
        </div>
        {canCreate ? (
          <Link
            href={
              entity
                ? `/money/transfers/new?entity=${encodeURIComponent(entity)}`
                : "/money/transfers/new"
            }
            className="btn-primary"
          >
            Buat Transfer
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status transfer">
          {TRANSFER_FILTER_OPTIONS.map((option) => (
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
            placeholder="Cari nomor transfer, akun, deskripsi…"
            aria-label="Cari transfer"
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
              ? "Tidak ada transfer yang cocok dengan pencarian ini."
              : "Belum ada transfer pada tampilan ini."}
          </p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">No. Transfer</th>
              <th scope="col">Dari</th>
              <th scope="col">Ke</th>
              <th scope="col">Tanggal</th>
              <th scope="col">Status</th>
              <th scope="col" className="num">
                Jumlah
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = transferListStatus(row);
              const href = entity
                ? `/money/transfers/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/money/transfers/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.transfer_number ?? "Draf"}</Link>
                  </td>
                  <td>{row.from_account_name}</td>
                  <td>{row.to_account_name}</td>
                  <td>{formatShortDate(row.transfer_date)}</td>
                  <td>
                    <span
                      className={`status-badge status-badge-${status.tone}`}
                    >
                      {status.text}
                    </span>
                  </td>
                  <td className="num">
                    {formatMoney(row.amount_out, row.from_account_currency)}
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

function filterLabel(filter: TransferListFilter): string {
  return (
    TRANSFER_FILTER_OPTIONS.find((option) => option.value === filter)?.label ??
    filter
  );
}
