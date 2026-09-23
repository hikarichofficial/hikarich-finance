import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  ACCOUNT_FILTER_OPTIONS,
  accountListStatus,
  type AccountListFilter,
  type AccountListRow,
} from "@/domain/money/accountsList";

/**
 * Accounts List (P13 Part 3c, Step 09 §9, §13: "Accounts screen shows each real bank/cash/e-wallet account,
 * current system balance, reconciliation status and recent activity"). Recent activity itself is Account
 * Detail's own ledger (`AccountDetailScreen`), not repeated per row here. Same header/toolbar/table/empty-
 * state structure `InvoicesListScreen`/`BillsListScreen` already established; search and filtering are a
 * plain GET round-trip over the page's own already-fetched, already-merged rows (`mergeAccountRows`), same
 * rationale as Sales/Purchases (no server-side free-text index yet). "Tambah Akun" is deferred to a later
 * increment and routes through the catch-all placeholder (DECISIONS 157) for now.
 */

function buildHref(
  entity: string | undefined,
  filter: AccountListFilter | null,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("status", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/money/accounts?${qs}` : "/money/accounts";
}

export function AccountsListScreen({
  rows,
  activeFilter,
  query,
  entity,
  canCreate,
}: {
  rows: readonly AccountListRow[];
  activeFilter: AccountListFilter | null;
  query: string;
  entity: string | undefined;
  canCreate: boolean;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Akun Kas &amp; Bank</h1>
          <p className="list-screen-summary">
            {rows.length} akun{" "}
            {activeFilter ? `pada tampilan "${filterLabel(activeFilter)}"` : "ditampilkan"}.
          </p>
        </div>
        {canCreate ? (
          <Link href="/money/accounts/new" className="btn-primary">
            Tambah Akun
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status akun">
          {ACCOUNT_FILTER_OPTIONS.map((option) => (
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
            placeholder="Cari nama atau jenis akun…"
            aria-label="Cari akun"
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
              ? "Tidak ada akun yang cocok dengan pencarian ini."
              : "Belum ada akun pada tampilan ini."}
          </p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nama Akun</th>
              <th scope="col">Jenis</th>
              <th scope="col">Status</th>
              <th scope="col" className="num">
                Saldo Sistem
              </th>
              <th scope="col" className="num">
                Saldo Buku Besar
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = accountListStatus(row);
              const href = entity
                ? `/money/accounts/${row.financial_account_id}?entity=${encodeURIComponent(entity)}`
                : `/money/accounts/${row.financial_account_id}`;
              return (
                <tr key={row.financial_account_id}>
                  <td>
                    <Link href={href}>{row.name}</Link>
                  </td>
                  <td>{row.kind}</td>
                  <td>
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  <td className="num">{formatMoney(row.movement_balance, row.currency)}</td>
                  <td className="num">{formatMoney(row.ledger_balance, row.currency)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

function filterLabel(filter: AccountListFilter): string {
  return ACCOUNT_FILTER_OPTIONS.find((option) => option.value === filter)?.label ?? filter;
}
