import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { monthLabel, pageWindow, STATEMENT_PAGE_SIZE } from "@/domain/accounting/cashStatement";
import type { CashAccountOption, CashStatement } from "@/schemas/cashStatement";
import { formatShortDate } from "./format";

/**
 * "Rekening Koran" (decision 326): the cash and bank accounts month by month, like a bank statement. Opening
 * balance, money in, money out and closing balance of the chosen month, then its lines with a running balance,
 * in pages of 20 that are reached with page-number buttons, plus a 12-month overview to jump between months.
 */
export function CashStatementScreen({
  statement,
  accounts,
  accountId,
  page,
  currency,
  entity,
}: {
  statement: CashStatement;
  accounts: readonly CashAccountOption[];
  accountId: string | null;
  page: number;
  currency: string;
  entity: string | undefined;
}) {
  const monthKey = statement.month_start.slice(0, 7);
  const totalPages = Math.max(1, Math.ceil(statement.total_rows / STATEMENT_PAGE_SIZE));

  function href(options: { month?: string; page?: number }): string {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (accountId) params.set("account", accountId);
    params.set("month", options.month ?? monthKey);
    if (options.page && options.page > 1) params.set("page", String(options.page));
    return `/accounting/statement?${params.toString()}`;
  }

  const money = (value: string) => formatMoney(value, currency);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Rekening Koran</h1>
          <p className="list-screen-summary">
            Uang masuk dan keluar kas &amp; bank per bulan, dari jurnal yang sudah diposting.
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Rekening
            <select name="account" defaultValue={accountId ?? ""}>
              <option value="">Semua Kas &amp; Bank</option>
              {accounts.map((account) => (
                <option key={account.id} value={account.id}>
                  {account.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Bulan
            <input type="month" name="month" defaultValue={monthKey} />
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      <section
        className="stmt-summary"
        aria-label={`Ringkasan ${monthLabel(statement.month_start)}`}
      >
        <div className="stmt-card">
          <span className="stmt-card-label">Saldo Awal</span>
          <strong>{money(statement.opening)}</strong>
        </div>
        <div className="stmt-card stmt-card-in">
          <span className="stmt-card-label">Uang Masuk</span>
          <strong>{money(statement.total_in)}</strong>
        </div>
        <div className="stmt-card stmt-card-out">
          <span className="stmt-card-label">Uang Keluar</span>
          <strong>{money(statement.total_out)}</strong>
        </div>
        <div className="stmt-card">
          <span className="stmt-card-label">Saldo Akhir</span>
          <strong>{money(statement.closing)}</strong>
        </div>
      </section>

      <h2 className="dashboard-section-title">{monthLabel(statement.month_start)}</h2>
      {statement.rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada uang masuk atau keluar pada bulan ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Tanggal</th>
              <th scope="col">No. Jurnal</th>
              <th scope="col">Keterangan</th>
              {accountId ? null : <th scope="col">Rekening</th>}
              <th scope="col" className="num">
                Masuk
              </th>
              <th scope="col" className="num">
                Keluar
              </th>
              <th scope="col" className="num">
                Saldo
              </th>
            </tr>
          </thead>
          <tbody>
            {statement.rows.map((row) => (
              <tr key={`${row.journal_id}-${row.rn}`}>
                <td data-label="Tanggal">{formatShortDate(row.entry_date)}</td>
                <td data-label="No. Jurnal">
                  <Link
                    href={
                      entity
                        ? `/accounting/journal/${row.journal_id}?entity=${encodeURIComponent(entity)}`
                        : `/accounting/journal/${row.journal_id}`
                    }
                  >
                    {row.journal_number ?? "Draf"}
                  </Link>
                </td>
                <td data-label="Keterangan">{row.description}</td>
                {accountId ? null : <td data-label="Rekening">{row.account_name}</td>}
                <td data-label="Masuk" className="num stmt-in">
                  {Number(row.masuk) > 0 ? money(row.masuk) : "–"}
                </td>
                <td data-label="Keluar" className="num stmt-out">
                  {Number(row.keluar) > 0 ? money(row.keluar) : "–"}
                </td>
                <td data-label="Saldo" className="num">
                  {money(row.saldo)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {totalPages > 1 ? (
        <nav className="stmt-pager" aria-label="Halaman rekening koran">
          {page > 1 ? (
            <Link className="stmt-page" href={href({ page: page - 1 })}>
              ‹ Sebelumnya
            </Link>
          ) : null}
          {pageWindow(page, totalPages).map((p, index) =>
            p === null ? (
              <span key={`gap-${index}`} className="stmt-page-gap">
                …
              </span>
            ) : (
              <Link
                key={p}
                className={p === page ? "stmt-page stmt-page-current" : "stmt-page"}
                href={href({ page: p })}
                aria-current={p === page ? "page" : undefined}
              >
                {p}
              </Link>
            ),
          )}
          {page < totalPages ? (
            <Link className="stmt-page" href={href({ page: page + 1 })}>
              Berikutnya ›
            </Link>
          ) : null}
          <span className="stmt-page-info">
            Halaman {Math.min(page, totalPages)} dari {totalPages} · {statement.total_rows} baris
          </span>
        </nav>
      ) : null}

      <h2 className="dashboard-section-title">Ringkasan 12 Bulan</h2>
      <table className="record-table record-table-stacked">
        <thead>
          <tr>
            <th scope="col">Bulan</th>
            <th scope="col" className="num">
              Uang Masuk
            </th>
            <th scope="col" className="num">
              Uang Keluar
            </th>
            <th scope="col" className="num">
              Saldo Akhir
            </th>
          </tr>
        </thead>
        <tbody>
          {[...statement.months].reverse().map((month) => (
            <tr
              key={month.month}
              className={month.month === statement.month_start ? "stmt-current-month" : undefined}
            >
              <td data-label="Bulan">
                <Link href={href({ month: month.month.slice(0, 7) })}>
                  {monthLabel(month.month)}
                </Link>
              </td>
              <td data-label="Uang Masuk" className="num stmt-in">
                {money(month.masuk)}
              </td>
              <td data-label="Uang Keluar" className="num stmt-out">
                {money(month.keluar)}
              </td>
              <td data-label="Saldo Akhir" className="num">
                {money(month.saldo_akhir)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
