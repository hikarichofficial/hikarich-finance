import Link from "next/link";
import {
  RECURRING_FREQUENCY_LABELS,
  RECURRING_KIND_LABELS,
  recurringRuleActions,
} from "@/domain/planning/planning";
import {
  recurringOccurrenceStatusBadge,
  recurringStatusBadge,
} from "@/domain/planning/recurringList";
import type { CategoryRow } from "@/schemas/categories";
import type {
  ContactPickerRow,
  FinancialAccountPickerRow,
  PaymentChannelPickerRow,
  RecurringOccurrenceRow,
  RecurringRuleRow,
} from "@/schemas/planning";
import { RecurringRuleActions, type RecurringRuleActionPermissions } from "./RecurringRuleActions";
import { RecurringRuleForm } from "./RecurringRuleForm";
import { formatShortDate } from "./format";

/** Only "invoices" and "bills" have a Detail route to link to yet -- "expenses" has no Detail screen built
 * in this repository so far (Part 3b shipped only Bills List/Detail, decisions 167-168), so a generated
 * expense is shown as plain text rather than a dead link, the same "only link what has somewhere to go"
 * precedent decision 172 already established for Loan Detail's own account references. */
const GENERATED_TABLE_HREF: Readonly<Partial<Record<"invoices" | "bills" | "expenses", string>>> = {
  invoices: "/sales/invoices",
  bills: "/purchases/bills",
};

/**
 * Recurring Rule Detail (P13 Part 3h, first increment, Step 09 §10, §18: "Editing a recurring rule explicitly
 * states that historical generated records will not change"). `list_recurring_rules` is the only rule-shaped
 * RPC (no `get_recurring_rule` exists) -- the same "no per-record RPC, fetch the list and find by id" precedent
 * decision 169 already established, reused again for Payroll Employee Detail (decision 179). Occurrence
 * history (`list_recurring_occurrences`) is fetched separately and always rendered (an empty-state message
 * rather than a hidden section) since generated history is this screen's own reason to exist, per Step 09
 * §18's own wording -- the same "always show, empty-state message" choice Loan Detail's schedule/payment
 * sections made (decision 175), not the "hide when empty" choice used for Payroll Run's optional
 * adjustments/payments sections. The template's own raw line items (`template`, arbitrary jsonb per kind) are
 * not rendered here -- a later increment's create/edit builder needs to interpret that shape anyway, so
 * showing a partial, un-interpreted rendering here first would be more confusing than nothing. Pause/Resume/
 * End are rendered as actual buttons by `RecurringRuleActions` (P13 Part 3h, fourth increment); the manual
 * "generate now" action (`runDueRecurringOccurrences`) is entity-wide rather than per-rule, so it lives on
 * the Register screen instead. `recurringRuleActions` stays the single eligibility source for both the hint
 * sentence below and the buttons, so they can never disagree. From the sixth increment: the template's own
 * raw line items ARE now interpretable (`RecurringRuleForm`), so this screen renders the create/edit builder
 * itself, pre-filled from `rule.template`, whenever `permissions.canManage` and the rule is not `ended`
 * (`actions.canEdit` -- the same eligibility source the buttons above already use, so the edit form and the
 * Pause/End buttons can never disagree about whether this rule may still be changed).
 *
 * On a narrow screen the Riwayat Pembuatan table becomes stacked cards (`record-table-stacked`,
 * `globals.css`; P13 Part 5; Step 09 §23), the same way `RecurringRuleRegisterScreen` already does (decision
 * 206) -- Tanggal as the unlabelled heading.
 */
export function RecurringRuleDetailScreen({
  rule,
  occurrences,
  entity,
  entityId,
  backHref,
  customers,
  vendors,
  accounts,
  channels,
  categories,
  permissions,
}: {
  rule: RecurringRuleRow;
  occurrences: readonly RecurringOccurrenceRow[];
  entity: string | undefined;
  entityId: string;
  backHref: string;
  customers: readonly ContactPickerRow[];
  vendors: readonly ContactPickerRow[];
  accounts: readonly FinancialAccountPickerRow[];
  channels: readonly PaymentChannelPickerRow[];
  categories: readonly CategoryRow[];
  permissions: RecurringRuleActionPermissions;
}) {
  const statusBadge = recurringStatusBadge(rule.status);
  const actions = recurringRuleActions(rule.status);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar aturan berulang</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Aturan Berulang · {RECURRING_KIND_LABELS[rule.kind]}
          </p>
          <h1>{rule.label}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Frekuensi</dt>
            <dd>
              {RECURRING_FREQUENCY_LABELS[rule.frequency]}
              {rule.frequency === "custom_days" ? ` (setiap ${rule.interval_count} hari)` : null}
            </dd>
          </div>
          <div>
            <dt>Batas Waktu Jatuh Tempo</dt>
            <dd>{rule.due_offset_days} hari setelah dibuat</dd>
          </div>
          <div>
            <dt>Tanggal Mulai</dt>
            <dd>{formatShortDate(rule.start_date)}</dd>
          </div>
          <div>
            <dt>Tanggal Berakhir</dt>
            <dd>{rule.end_date ? formatShortDate(rule.end_date) : "Tidak ditentukan"}</dd>
          </div>
          <div>
            <dt>Kejadian Berikutnya</dt>
            <dd>{formatShortDate(rule.next_occurrence_date)}</dd>
          </div>
          <div>
            <dt>Terakhir Dibuat</dt>
            <dd>{rule.last_generated_date ? formatShortDate(rule.last_generated_date) : "—"}</dd>
          </div>
          {rule.note ? (
            <div>
              <dt>Catatan</dt>
              <dd>{rule.note}</dd>
            </div>
          ) : null}
          {rule.paused_at ? (
            <div>
              <dt>Dijeda Pada</dt>
              <dd>
                {formatShortDate(rule.paused_at.slice(0, 10))}
                {rule.paused_reason ? ` — ${rule.paused_reason}` : null}
              </dd>
            </div>
          ) : null}
          {rule.ended_at ? (
            <div>
              <dt>Berakhir Pada</dt>
              <dd>
                {formatShortDate(rule.ended_at.slice(0, 10))}
                {rule.ended_reason ? ` — ${rule.ended_reason}` : null}
              </dd>
            </div>
          ) : null}
        </dl>
        <p className="hint">
          {actions.canEdit ? "Dapat diedit. " : "Tidak dapat diedit lagi. "}
          Mengedit aturan ini tidak mengubah catatan yang sudah dibuat sebelumnya.
        </p>
        <RecurringRuleActions ruleId={rule.id} status={rule.status} permissions={permissions} />
      </section>

      {permissions.canManage && actions.canEdit ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Template</h2>
          </div>
          <RecurringRuleForm
            mode="edit"
            entityId={entityId}
            entity={entity}
            rule={rule}
            customers={customers}
            vendors={vendors}
            accounts={accounts}
            channels={channels}
            categories={categories}
          />
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Pembuatan</h2>
        </div>
        {occurrences.length === 0 ? (
          <p className="dashboard-empty">Belum ada kejadian yang dibuat.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Status</th>
                <th scope="col">Percobaan</th>
                <th scope="col">Terakhir Dicoba</th>
                <th scope="col">Hasil</th>
              </tr>
            </thead>
            <tbody>
              {occurrences.map((occurrence) => {
                const badge = recurringOccurrenceStatusBadge(occurrence.status);
                return (
                  <tr key={occurrence.id}>
                    <td>{formatShortDate(occurrence.occurrence_date)}</td>
                    <td data-label="Status">
                      <span className={`status-badge status-badge-${badge.tone}`}>
                        {badge.text}
                      </span>
                    </td>
                    <td data-label="Percobaan">{occurrence.attempts}</td>
                    <td data-label="Terakhir Dicoba">
                      {formatShortDate(occurrence.last_attempted_at.slice(0, 10))}
                    </td>
                    <td data-label="Hasil">
                      {(() => {
                        const base =
                          occurrence.generated_table &&
                          GENERATED_TABLE_HREF[occurrence.generated_table];
                        if (base && occurrence.generated_id) {
                          const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
                          return (
                            <Link href={`${base}/${occurrence.generated_id}${qs}`}>Lihat →</Link>
                          );
                        }
                        if (occurrence.generated_table && occurrence.generated_id) {
                          return "Dibuat";
                        }
                        return occurrence.last_error ?? "—";
                      })()}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
