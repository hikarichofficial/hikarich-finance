import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { sourceTypeLabel } from "@/domain/money/accountsList";
import type { CashActivityRow } from "@/domain/money/cashActivity";
import type { MoneyControlRow } from "@/schemas/money";
import { formatShortDate } from "./format";

/**
 * Cash/Bank Activity (P13 Part 3c, Step 09 §13's fourth Money nav item): an Entity-wide, chronological feed
 * across every account, following the Standard List Screen Pattern (Step 09 §9) with an account filter in
 * place of the usual status filter tabs (this feed has no workflow status of its own -- every movement here
 * is already posted; "recent, high-value events" is Dashboard's own curated slice, this is the fuller list
 * behind it). No running balance column: unlike Account Detail's single-account ledger, a running balance
 * across mixed accounts and currencies would not be a meaningful number.
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5,
 * fourth increment; Step 09 §23), the same way `InvoicesListScreen` already does (decision 202). Tanggal
 * stays the unlabelled heading line here rather than the drill-down `Akun` link -- date is this feed's own
 * natural chronological grouping key, and the `Akun` link itself stays reachable one labelled row down.
 */
export function CashActivityScreen({
  rows,
  accounts,
  accountId,
  query,
  range,
  entity,
}: {
  rows: readonly CashActivityRow[];
  accounts: readonly MoneyControlRow[];
  accountId: string | null;
  query: string;
  range: { from: string; to: string };
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Aktivitas Kas &amp; Bank</h1>
          <p className="list-screen-summary">{rows.length} pergerakan ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Akun
            <select name="account" defaultValue={accountId ?? ""}>
              <option value="">Semua akun</option>
              {accounts.map((a) => (
                <option key={a.financial_account_id} value={a.financial_account_id}>
                  {a.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Dari
            <input type="date" name="from" defaultValue={range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={range.to} />
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari akun, jenis, deskripsi, jurnal…"
            aria-label="Cari aktivitas"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada pergerakan pada rentang dan saringan ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Tanggal</th>
              <th scope="col">Akun</th>
              <th scope="col">Keterangan</th>
              <th scope="col">Jurnal</th>
              <th scope="col" className="num">
                Masuk
              </th>
              <th scope="col" className="num">
                Keluar
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((movement) => {
              const href = entity
                ? `/money/accounts/${movement.financial_account_id}?entity=${encodeURIComponent(entity)}`
                : `/money/accounts/${movement.financial_account_id}`;
              return (
                <tr key={movement.id}>
                  <td>{formatShortDate(movement.movement_date)}</td>
                  <td data-label="Akun">
                    <Link href={href}>{movement.account_name}</Link>
                  </td>
                  <td data-label="Keterangan">
                    {sourceTypeLabel(movement.source_type)}
                    {movement.description ? ` — ${movement.description}` : ""}
                    {movement.reverses_movement_id ? " (pembalik)" : ""}
                  </td>
                  <td data-label="Jurnal">{movement.journal_number ?? "—"}</td>
                  <td className="num amt-in" data-label="Masuk">
                    {movement.direction === "in"
                      ? formatMoney(movement.amount, movement.account_currency)
                      : ""}
                  </td>
                  <td className="num amt-out" data-label="Keluar">
                    {movement.direction === "out"
                      ? formatMoney(movement.amount, movement.account_currency)
                      : ""}
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
