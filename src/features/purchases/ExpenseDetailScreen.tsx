import Link from "next/link";
import type { ReactNode } from "react";
import { formatMoney } from "@/domain/money/format";
import {
  EXPENSE_STATUS_LABELS,
  EXPENSE_STATUS_TONE,
  type ExpenseActionSet,
} from "@/domain/purchases/expenseList";
import type { ExpenseLineRow, ExpenseRow } from "@/schemas/expenses";
import { ExpenseActions } from "./ExpenseActions";
import { formatShortDate } from "./format";

/** Direct Expense Detail (Step 09 §10/§12, decision 245): Header, Actions, Ringkasan, Baris, and links to
 * its journal(s) and to the expense it replaces or is replaced by. */

const TREATMENT_LABELS = { expense: "Beban", asset: "Aset", prepaid: "Dibayar di muka" } as const;

export function ExpenseDetailScreen({
  expense,
  lines,
  payeeLabel,
  accountName,
  categoryNames,
  actions,
  entity,
  backHref,
  canEdit = false,
  documents,
  taxPanel,
}: {
  expense: ExpenseRow;
  lines: readonly ExpenseLineRow[];
  payeeLabel: string;
  accountName: string;
  categoryNames: ReadonlyMap<string, string>;
  actions: ExpenseActionSet;
  entity: string | undefined;
  backHref: string;
  /** Shows "Ubah Draf" on a draft (`bills.edit`, the permission `update_expense_draft` checks). */
  canEdit?: boolean;
  /** The attachments of this expense, shown inside the Dokumen section (decision 332). */
  documents?: ReactNode;
  /** What the tax engine would decide before the expense is recorded (draft and submitted only). */
  taxPanel?: ReactNode;
}) {
  const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";
  const money = (value: string) => formatMoney(value, expense.currency);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar pengeluaran</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pengeluaran</p>
          <h1>{expense.expense_number ?? "Draf Pengeluaran"}</h1>
          <p className="record-detail-counterparty">{payeeLabel}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${EXPENSE_STATUS_TONE[expense.status]}`}>
            {EXPENSE_STATUS_LABELS[expense.status]}
          </span>
          <p className="record-detail-amount">{money(expense.total)}</p>
          <p className="record-detail-dates">{formatShortDate(expense.expense_date)}</p>
        </div>
      </header>

      <ExpenseActions
        expenseId={expense.id}
        actions={actions}
        entity={entity}
        status={expense.status}
      />
      {expense.status === "draft" && canEdit ? (
        <p>
          <Link href={`/purchases/expenses/${expense.id}/edit${suffix}`} className="btn-secondary">
            Ubah Draf
          </Link>
        </p>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Dibayar dari</dt>
            <dd>{accountName}</dd>
          </div>
          <div>
            <dt>Subtotal</dt>
            <dd>{money(expense.subtotal)}</dd>
          </div>
          <div>
            <dt>Pajak</dt>
            <dd>{money(expense.tax_total)}</dd>
          </div>
          <div>
            <dt>Nomor Struk</dt>
            <dd>{expense.receipt_reference ?? "—"}</dd>
          </div>
          {expense.reject_reason ? (
            <div>
              <dt>Alasan Penolakan Terakhir</dt>
              <dd>{expense.reject_reason}</dd>
            </div>
          ) : null}
          {expense.closed_reason ? (
            <div>
              <dt>Alasan Pembatalan/Pembalikan</dt>
              <dd>{expense.closed_reason}</dd>
            </div>
          ) : null}
          {expense.notes ? (
            <div>
              <dt>Catatan</dt>
              <dd>{expense.notes}</dd>
            </div>
          ) : null}
          {expense.journal_id ? (
            <div>
              <dt>Jurnal</dt>
              <dd>
                <Link href={`/accounting/journal/${expense.journal_id}${suffix}`}>
                  Lihat jurnal
                </Link>
                {expense.reversal_journal_id ? (
                  <>
                    {" · "}
                    <Link href={`/accounting/journal/${expense.reversal_journal_id}${suffix}`}>
                      Jurnal pembalik
                    </Link>
                  </>
                ) : null}
              </dd>
            </div>
          ) : null}
          {expense.replaces_expense_id ? (
            <div>
              <dt>Menggantikan</dt>
              <dd>
                <Link href={`/purchases/expenses/${expense.replaces_expense_id}${suffix}`}>
                  Pengeluaran sebelumnya
                </Link>
              </dd>
            </div>
          ) : null}
          {expense.replaced_by_expense_id ? (
            <div>
              <dt>Digantikan oleh</dt>
              <dd>
                <Link href={`/purchases/expenses/${expense.replaced_by_expense_id}${suffix}`}>
                  Pengeluaran pengganti
                </Link>
              </dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Baris</h2>
        </div>
        {lines.length === 0 ? (
          <p>Belum ada baris.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Deskripsi</th>
                <th scope="col">Kategori</th>
                <th scope="col">Perlakuan</th>
                <th scope="col" className="num">
                  Kuantitas
                </th>
                <th scope="col" className="num">
                  Harga Satuan
                </th>
                <th scope="col" className="num">
                  Total
                </th>
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={line.id}>
                  <td>{line.description}</td>
                  <td data-label="Kategori">
                    {line.category_id ? (categoryNames.get(line.category_id) ?? "—") : "—"}
                  </td>
                  <td data-label="Perlakuan">{TREATMENT_LABELS[line.treatment]}</td>
                  <td className="num" data-label="Kuantitas">
                    {Number(line.quantity).toLocaleString("id-ID")}
                  </td>
                  <td className="num" data-label="Harga Satuan">
                    {money(line.unit_price)}
                  </td>
                  <td className="num" data-label="Total">
                    {money(line.line_total)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {taxPanel}

      {documents ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Dokumen</h2>
          </div>
          {documents}
        </section>
      ) : null}
    </div>
  );
}
