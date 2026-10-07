import Link from "next/link";
import { RECURRING_FREQUENCY_LABELS, RECURRING_KIND_LABELS } from "@/domain/planning/planning";
import {
  RECURRING_STATUS_FILTER_OPTIONS,
  recurringStatusBadge,
  type RecurringStatusFilterOption,
} from "@/domain/planning/recurringList";
import type { RecurringRuleRow } from "@/schemas/planning";
import type { RecurringStatus } from "@/domain/planning/planning";
import { RunDueRecurringOccurrencesButton } from "./RecurringRuleActions";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Recurring Rules Register (P13 Part 3h, first increment, Step 09 §9, §18: "Recurring Rules list shows next
 * run, status, frequency and generated history"). Follows the same Standard List Screen Pattern as every
 * other Part 3 register: `list_recurring_rules`'s own `p_status` argument is sent server-side (matching the
 * Loan/Payroll Run registers' own split), and only the free-text label search is client-side since no RPC
 * parameter covers it. The manual "generate now" action (`planning.recurring_run`, P13 Part 3h, fourth
 * increment) is entity-wide rather than per-rule, so its button lives here in the header rather than on
 * Detail. From the sixth increment: the "Buat Transaksi Berulang" button (`canCreate`, `planning.recurring_edit`,
 * the exact permission `create_recurring_rule` itself checks) follows the identical conditional-Link-button
 * precedent `BudgetRegisterScreen`/`AccountsListScreen`/`InvoicesListScreen` already established, reaching
 * the create/edit template builder (`RecurringRuleForm`) that decisions 186/187 had deferred.
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5;
 * Step 09 §23), the same way `InvoicesListScreen` already does (decision 202) -- Nama as the unlabelled
 * heading link. The empty state carries one CTA (Step 09 §9/§25, Step 10 §24, decision 218), the same
 * "Hapus Saringan"-or-header-action pattern `BudgetRegisterScreen` established.
 */
export function RecurringRuleRegisterScreen({
  rows,
  status,
  query,
  entity,
  entityId,
  canRun,
  canCreate,
}: {
  rows: readonly RecurringRuleRow[];
  status: RecurringStatus | null;
  query: string;
  entity: string | undefined;
  entityId: string;
  canRun: boolean;
  canCreate: boolean;
}) {
  const newHref = entity
    ? `/planning/recurring/new?entity=${encodeURIComponent(entity)}`
    : "/planning/recurring/new";
  const baseHref = entity
    ? `/planning/recurring?entity=${encodeURIComponent(entity)}`
    : "/planning/recurring";
  const isFiltered = Boolean(status) || query.trim().length > 0;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Transaksi Berulang</h1>
          <p className="list-screen-summary">{rows.length} transaksi berulang ditampilkan.</p>
          <p className="list-screen-summary">
            Draf dibuat otomatis setiap hari pada tanggalnya. Setelah itu, terbitkan atau setujui
            draf tersebut seperti biasa.
          </p>
        </div>
        <div className="invoice-actions">
          {canCreate ? (
            <Link href={newHref} className="btn-primary">
              Buat Transaksi Berulang
            </Link>
          ) : null}
          <RunDueRecurringOccurrencesButton entityId={entityId} canRun={canRun} />
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {RECURRING_STATUS_FILTER_OPTIONS.map((option: RecurringStatusFilterOption) => (
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
            placeholder="Cari nama aturan…"
            aria-label="Cari transaksi berulang"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada transaksi berulang pada saringan ini.</p>
          {isFiltered ? (
            <Link href={baseHref} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : canCreate ? (
            <Link href={newHref} className="btn-primary list-empty-action">
              Buat Transaksi Berulang
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis</th>
              <th scope="col">Frekuensi</th>
              <th scope="col">Berikutnya</th>
              <th scope="col">Terakhir Dibuat</th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const badge = recurringStatusBadge(row.status);
              const href = entity
                ? `/planning/recurring/${row.id}?entity=${encodeURIComponent(entity)}`
                : `/planning/recurring/${row.id}`;
              return (
                <tr key={row.id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.label}
                      eyebrow="Transaksi Berulang"
                      title={row.label}
                      badges={[{ tone: badge.tone, text: badge.text }]}
                      fields={[
                        { label: "Jenis", value: RECURRING_KIND_LABELS[row.kind] },
                        { label: "Frekuensi", value: RECURRING_FREQUENCY_LABELS[row.frequency] },
                        { label: "Berikutnya", value: formatShortDate(row.next_occurrence_date) },
                        {
                          label: "Terakhir Dibuat",
                          value: row.last_generated_date
                            ? formatShortDate(row.last_generated_date)
                            : "—",
                        },
                      ]}
                    />
                  </td>
                  <td data-label="Jenis">{RECURRING_KIND_LABELS[row.kind]}</td>
                  <td data-label="Frekuensi">{RECURRING_FREQUENCY_LABELS[row.frequency]}</td>
                  <td data-label="Berikutnya">{formatShortDate(row.next_occurrence_date)}</td>
                  <td data-label="Terakhir Dibuat">
                    {row.last_generated_date ? formatShortDate(row.last_generated_date) : "—"}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
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
