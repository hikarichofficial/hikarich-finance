import { formatMoney } from "@/domain/money/format";
import {
  accountListStatus,
  sourceTypeLabel,
  type AccountListRow,
} from "@/domain/money/accountsList";
import type { AccountActivityRow } from "@/schemas/money";
import { Decimal } from "@/domain/money/decimal";
import { formatShortDate } from "./format";
import {
  DeleteAccountForm,
  EditAccountDetailsForm,
  ToggleAccountActiveForm,
} from "./AccountManageForms";
import { BackLink } from "@/features/shell/BackLink";

/**
 * Account Detail (P13 Part 3c, Step 09 §10, §13: "Account detail resembles a clean bank ledger with filters,
 * running balance and source links"). Unlike Invoice/Bill Detail, an account is not itself a commercial
 * document with issue/void/correct actions, so this screen keeps only the two Standard Record Detail Pattern
 * areas that actually apply -- Header and a Summary that doubles as the ledger's own Activity -- rather than
 * padding out Accounting/Tax/Audit placeholders that would say nothing an account doesn't already show here.
 * Source links (Step 09 §13) are deferred: `account_activity`'s `source_type`/`source_id` point at records
 * (payments, refunds, vendor payments, transfers, tax payments...) that mostly don't have their own detail
 * screen yet in this codebase (only Invoices/Bills do, and neither is `money_movements`' own source_id), so
 * linking out today would mean guessing at routes rather than reading an actual established one.
 *
 * On a narrow screen the Activity table becomes stacked cards (`record-table-stacked`, `globals.css`; P13
 * Part 5; Step 09 §23), the same treatment `CashActivityScreen` already uses (decision 203) -- Tanggal stays
 * the unlabelled heading rather than a drill-down link, since this is already scoped to one account and date
 * is the natural reading key for a ledger.
 */
export function AccountDetailScreen({
  account,
  activity,
  backHref,
  range,
  entity,
  canManage,
  canDelete,
  hasHistory,
  editable,
}: {
  account: AccountListRow;
  activity: readonly AccountActivityRow[];
  backHref: string;
  range: { from: string; to: string };
  entity: string | undefined;
  canManage: boolean;
  canDelete: boolean;
  hasHistory: boolean;
  /** Current name/institution/holder for the edit form; `null` hides it. */
  editable: { name: string; institution_name: string; account_holder: string } | null;
}) {
  const status = accountListStatus(account);
  let totalIn = Decimal.parse("0");
  let totalOut = Decimal.parse("0");
  for (const movement of activity) {
    if (movement.direction === "in") totalIn = totalIn.add(Decimal.parse(movement.amount));
    else totalOut = totalOut.add(Decimal.parse(movement.amount));
  }
  const baseDiffers = account.currency !== "IDR";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <BackLink href={backHref}>← Kembali ke daftar akun</BackLink>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Akun Kas &amp; Bank · {account.kind}</p>
          <h1>{account.name}</h1>
          {account.account_masked ? (
            <p className="record-detail-eyebrow">No. Rekening {account.account_masked}</p>
          ) : null}
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-amount">
            {formatMoney(account.movement_balance, account.currency)}
          </p>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Saldo Sistem</dt>
            <dd>{formatMoney(account.movement_balance, account.currency)}</dd>
          </div>
          {baseDiffers ? (
            <div>
              <dt>Saldo Sistem (IDR)</dt>
              <dd>{formatMoney(account.movement_base_balance, "IDR")}</dd>
            </div>
          ) : null}
          <div>
            <dt>Saldo Buku Besar</dt>
            <dd>{formatMoney(account.ledger_balance, account.currency)}</dd>
          </div>
          <div>
            <dt>Selisih</dt>
            <dd>{formatMoney(account.difference, account.currency)}</dd>
          </div>
          <div>
            <dt>Terakhir Direkonsiliasi</dt>
            <dd>
              {account.reconciliation?.last_reconciled_until
                ? formatShortDate(account.reconciliation.last_reconciled_until)
                : "Belum pernah"}
            </dd>
          </div>
          <div>
            <dt>Total Masuk (rentang ini)</dt>
            <dd>{formatMoney(totalIn.toString(), account.currency)}</dd>
          </div>
          <div>
            <dt>Total Keluar (rentang ini)</dt>
            <dd>{formatMoney(totalOut.toString(), account.currency)}</dd>
          </div>
          {account.reconciliation && account.reconciliation.unresolved_lines > 0 ? (
            <div>
              <dt>Baris Belum Selesai</dt>
              <dd>{account.reconciliation.unresolved_lines}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <p className="hint">
          Saldo bertambah saat pembayaran invoice diterima di rekening ini dan berkurang saat
          pengeluaran, pembayaran tagihan, atau pajak dibayar dari rekening ini.
        </p>
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Dari
            <input type="date" name="from" defaultValue={range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={range.to} />
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
        {activity.length === 0 ? (
          <p className="dashboard-empty">Tidak ada aktivitas pada rentang tanggal ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Keterangan</th>
                <th scope="col">Jurnal</th>
                <th scope="col" className="num">
                  Masuk
                </th>
                <th scope="col" className="num">
                  Keluar
                </th>
                <th scope="col" className="num">
                  Saldo Berjalan
                </th>
              </tr>
            </thead>
            <tbody>
              {activity.map((movement) => (
                <tr key={movement.movement_id}>
                  <td>{formatShortDate(movement.movement_date)}</td>
                  <td data-label="Keterangan">
                    {sourceTypeLabel(movement.source_type)}
                    {movement.description ? ` — ${movement.description}` : ""}
                    {movement.reverses_movement_id ? " (pembalik)" : ""}
                  </td>
                  <td data-label="Jurnal">{movement.journal_number ?? "—"}</td>
                  <td className="num amt-in" data-label="Masuk">
                    {movement.direction === "in"
                      ? formatMoney(movement.amount, movement.currency)
                      : ""}
                  </td>
                  <td className="num amt-out" data-label="Keluar">
                    {movement.direction === "out"
                      ? formatMoney(movement.amount, movement.currency)
                      : ""}
                  </td>
                  <td className="num" data-label="Saldo Berjalan">
                    {formatMoney(movement.running_balance, movement.currency)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {canManage ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Kelola Rekening</h2>
          </div>
          <p className="hint">
            {hasHistory
              ? "Rekening ini sudah punya transaksi. Anda boleh menghapusnya (ada dua langkah konfirmasi): rekening hilang dari semua daftar, riwayatnya tetap tersimpan. Atau cukup nonaktifkan (saldo harus nol) agar tidak muncul di pilihan pembayaran."
              : "Rekening ini belum punya transaksi. Anda boleh menghapusnya (ada dua langkah konfirmasi)."}
          </p>
          {editable ? (
            <EditAccountDetailsForm
              entity={entity}
              accountId={account.financial_account_id}
              current={editable}
              maskedNumber={account.account_masked}
            />
          ) : null}
          <ToggleAccountActiveForm
            entity={entity}
            accountId={account.financial_account_id}
            isActive={account.is_active}
          />
          {canDelete ? (
            <DeleteAccountForm
              entity={entity}
              accountId={account.financial_account_id}
              accountName={account.name}
              hasHistory={hasHistory}
              balanceText={formatMoney(account.movement_balance, account.currency)}
            />
          ) : null}
        </section>
      ) : null}
    </div>
  );
}
