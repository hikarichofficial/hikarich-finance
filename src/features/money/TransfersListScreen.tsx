import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  TRANSFER_FILTER_OPTIONS,
  transferListStatus,
  type TransferListFilter,
  type TransferListRow,
} from "@/domain/money/transferList";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Transfers List (P13 Part 3c, Step 09 §9, §13), the exact structure `InvoicesListScreen`/`BillsListScreen`
 * already established. Unlike Sales/Purchases, the create action here already routes to a real page
 * (`/money/transfers/new`) rather than the catch-all placeholder -- the Transfer form is small enough that
 * Part 3c builds it alongside List/Detail rather than deferring it (decision 164's own "materially larger"
 * test for when to defer a builder).
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5;
 * Step 09 §23), the same way `InvoicesListScreen` already does (decision 202) -- No. Transfer as the
 * unlabelled heading link. The empty state carries one CTA (Step 09 §9/§25, Step 10 §24, decision 218):
 * "Hapus Saringan" when filtered/searched to zero rows, else the header's own "Buat Transfer" action.
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
            {activeFilter ? `pada tampilan "${filterLabel(activeFilter)}"` : "ditampilkan"}.
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
          {activeFilter ? <input type="hidden" name="status" value={activeFilter} /> : null}
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
          {query.trim() || activeFilter ? (
            <Link href={buildHref(entity, null, "")} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : canCreate ? (
            <Link
              href={
                entity
                  ? `/money/transfers/new?entity=${encodeURIComponent(entity)}`
                  : "/money/transfers/new"
              }
              className="btn-primary list-empty-action"
            >
              Buat Transfer
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
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
                    <RecordPreviewLink
                      href={href}
                      label={row.transfer_number ?? "Draf"}
                      eyebrow="Transfer Antar Akun"
                      title={row.transfer_number ?? "Draf"}
                      badges={[{ tone: status.tone, text: status.text }]}
                      fields={[
                        { label: "Dari", value: row.from_account_name },
                        { label: "Ke", value: row.to_account_name },
                        { label: "Tanggal", value: formatShortDate(row.transfer_date) },
                        {
                          label: "Jumlah",
                          value: formatMoney(row.amount_out, row.from_account_currency),
                        },
                      ]}
                    />
                  </td>
                  <td data-label="Dari">{row.from_account_name}</td>
                  <td data-label="Ke">{row.to_account_name}</td>
                  <td data-label="Tanggal">{formatShortDate(row.transfer_date)}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td className="num" data-label="Jumlah">
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
  return TRANSFER_FILTER_OPTIONS.find((option) => option.value === filter)?.label ?? filter;
}
