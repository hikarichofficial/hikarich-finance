import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  monthLabel,
  pageWindow,
  shiftMonth,
  STATEMENT_PAGE_SIZE,
} from "@/domain/accounting/cashStatement";
import type { CashAccountOption, CashStatement } from "@/schemas/cashStatement";
import { formatShortDate } from "./format";

/**
 * One month of the "Rekening Koran" (decisions 326-327), on its own page for focus: opening balance, money in,
 * money out and closing balance of the month, then its lines with a running balance, in pages of 20 that are
 * reached with page-number buttons. The 12-month overview lives on the main Rekening Koran page.
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

  const yearHref = (() => {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (accountId) params.set("account", accountId);
    params.set("year", monthKey.slice(0, 4));
    return `/accounting/statement?${params.toString()}`;
  })();

  function href(options: { month?: string; page?: number }): string {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (accountId) params.set("account", accountId);
    if (options.page && options.page > 1) params.set("page", String(options.page));
    const query = params.toString();
    return `/accounting/statement/${options.month ?? monthKey}${query ? `?${query}` : ""}`;
  }

  const money = (value: string) => formatMoney(value, currency);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <p className="list-screen-summary">
            <Link href={yearHref}>‹ Rekening Koran {monthKey.slice(0, 4)}</Link>
          </p>
          <h1>Rekening Koran {monthLabel(statement.month_start)}</h1>
          <p className="list-screen-summary">
            {accountId
              ? (accounts.find((account) => account.id === accountId)?.name ?? "Satu rekening")
              : "Semua Kas & Bank"}{" "}
            · dari jurnal yang sudah diposting.
          </p>
        </div>
      </header>

      <nav className="stmt-pager" aria-label="Pindah bulan">
        <Link className="stmt-page" href={href({ month: shiftMonth(monthKey, -1) })}>
          ‹ {monthLabel(`${shiftMonth(monthKey, -1)}-01`)}
        </Link>
        <Link className="stmt-page" href={href({ month: shiftMonth(monthKey, 1) })}>
          {monthLabel(`${shiftMonth(monthKey, 1)}-01`)} ›
        </Link>
      </nav>

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
    </div>
  );
}
