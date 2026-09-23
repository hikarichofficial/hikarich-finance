import {
  COA_STATUS_FILTER_OPTIONS,
  accountClassLabel,
  buildCoaTree,
  coaIndicators,
  coaVisibleIds,
  type CoaStatusFilter,
} from "@/domain/accounting/coaList";
import type { LedgerAccountRow } from "@/schemas/accounting";

/**
 * Chart of Accounts (P13 Part 3d, Step 09 §14: "COA uses hierarchical tree/list with search, account status
 * and protected-control indicators"). Read-only: `public.ledger_accounts` is seeded once from a COA template
 * at Entity setup and has no create/edit RPC yet (`src/domain/accounting/coaList.ts`'s own doc comment), so
 * unlike every other list screen in this codebase there is no Create button here -- showing one would promise
 * an action the database cannot perform.
 */

export function ChartOfAccountsScreen({
  accounts,
  status,
  query,
  entity,
}: {
  accounts: readonly LedgerAccountRow[];
  status: CoaStatusFilter | null;
  query: string;
  entity: string | undefined;
}) {
  const visible = coaVisibleIds(accounts, status, query);
  const tree = buildCoaTree(accounts, visible);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Bagan Akun</h1>
          <p className="list-screen-summary">{tree.length} akun ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {COA_STATUS_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari kode atau nama akun…"
            aria-label="Cari akun"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {tree.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada akun pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Kode</th>
              <th scope="col">Nama Akun</th>
              <th scope="col">Kelas</th>
              <th scope="col">Saldo Normal</th>
              <th scope="col">Status</th>
              <th scope="col">Indikator</th>
            </tr>
          </thead>
          <tbody>
            {tree.map(({ account, depth }) => (
              <tr key={account.id}>
                <td style={{ paddingLeft: `${depth * 1.5}rem` }}>{account.code}</td>
                <td>{account.name}</td>
                <td>{accountClassLabel(account.account_class)}</td>
                <td>{account.normal_balance === "debit" ? "Debit" : "Kredit"}</td>
                <td>
                  <span
                    className={`status-badge status-badge-${account.status === "active" ? "success" : "neutral"}`}
                  >
                    {account.status === "active" ? "Aktif" : "Tidak Aktif"}
                  </span>
                </td>
                <td>
                  {coaIndicators(account).map((indicator) => (
                    <span
                      key={indicator.text}
                      className={`status-badge status-badge-${indicator.tone}`}
                    >
                      {indicator.text}
                    </span>
                  ))}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
