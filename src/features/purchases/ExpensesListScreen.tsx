import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  EXPENSE_FILTER_OPTIONS,
  EXPENSE_STATUS_LABELS,
  EXPENSE_STATUS_TONE,
  expensePayeeLabel,
} from "@/domain/purchases/expenseList";
import type { ExpenseRow, ExpenseStatus } from "@/schemas/expenses";
import { formatShortDate } from "./format";

/** Direct Expenses List (Step 09 §3 Purchases, §12; decision 245). */

function buildHref(
  entity: string | undefined,
  status: ExpenseStatus | undefined,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (status) params.set("status", status);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/purchases/expenses?${qs}` : "/purchases/expenses";
}

export function ExpensesListScreen({
  rows,
  vendorNames,
  activeStatus,
  query,
  entity,
  canCreate,
}: {
  rows: readonly ExpenseRow[];
  vendorNames: ReadonlyMap<string, string>;
  activeStatus: ExpenseStatus | undefined;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  const newHref = entity
    ? `/purchases/expenses/new?entity=${encodeURIComponent(entity)}`
    : "/purchases/expenses/new";

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Pengeluaran</h1>
          <p className="list-screen-summary">{rows.length} pengeluaran ditampilkan.</p>
          <p className="hint">
            Halaman ini hanya untuk belanja yang langsung dibayar. Beban dari tagihan vendor yang
            belum dibayar ada di menu{" "}
            <Link
              href={
                entity
                  ? `/purchases/bills?entity=${encodeURIComponent(entity)}`
                  : "/purchases/bills"
              }
            >
              Tagihan
            </Link>
            ; keduanya ikut dihitung sebagai Beban di dashboard dan Laba Rugi.
          </p>
        </div>
        {canCreate ? (
          <Link href={newHref} className="btn-primary">
            Catat Pengeluaran
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status pengeluaran">
          {EXPENSE_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(entity, option.value, query)}
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
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          {activeStatus ? <input type="hidden" name="status" value={activeStatus} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor, penerima atau struk…"
            aria-label="Cari pengeluaran"
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>
            {activeStatus || query.trim()
              ? "Tidak ada pengeluaran yang cocok."
              : "Belum ada pengeluaran. Catat belanja yang dibayar langsung di sini."}
          </p>
          {canCreate && !activeStatus && !query.trim() ? (
            <Link href={newHref} className="btn-primary list-empty-action">
              Catat Pengeluaran
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Penerima</th>
              <th scope="col">Tanggal</th>
              <th scope="col" className="num">
                Total
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const href = entity
                ? `/purchases/expenses/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/purchases/expenses/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <Link href={href}>{row.expense_number ?? "(belum bernomor)"}</Link>
                  </td>
                  <td data-label="Penerima">{expensePayeeLabel(row, vendorNames)}</td>
                  <td data-label="Tanggal">{formatShortDate(row.expense_date)}</td>
                  <td className="num" data-label="Total">
                    {formatMoney(row.total, row.currency)}
                  </td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${EXPENSE_STATUS_TONE[row.status]}`}
                    >
                      {EXPENSE_STATUS_LABELS[row.status]}
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
