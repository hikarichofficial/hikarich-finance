"use client";

import { useActionState, useState } from "react";
import {
  RECURRING_FREQUENCY_LABELS,
  RECURRING_KIND_LABELS,
  type RecurringFrequency,
  type RecurringKind,
} from "@/domain/planning/planning";
import type { CategoryRow } from "@/schemas/categories";
import type {
  ContactPickerRow,
  FinancialAccountPickerRow,
  PaymentChannelPickerRow,
  RecurringRuleRow,
} from "@/schemas/planning";
import {
  createRecurringRuleAction,
  updateRecurringRuleAction,
  idlePlanningActionState,
} from "./actions";
import {
  RecurringLinesEditor,
  buildInitialRecurringLines,
  buildRecurringLinesJson,
  type RecurringLineRow,
} from "./RecurringLinesEditor";

/**
 * The recurring template create/edit builder itself (P13 Part 3h, sixth increment, Step 09 §13, §18) --
 * decisions 186/187's own "still explicitly deferred... materially larger... arbitrary per-kind jsonb
 * template shape rather than a fixed set of fields" piece. One form covers both create and edit (the same
 * "genuinely shared, not just similarly shaped" reasoning `CreatePlanForm` already applied) because
 * `update_recurring_rule`'s own patch replaces `template` wholesale, exactly like `create_recurring_rule`
 * builds it fresh -- the header fields and lines editor below are identical in both modes. What differs is
 * `kind`, `frequency` and `start_date`: confirmed directly against `update_recurring_rule`'s own SQL body
 * (`20260928100100_p10_recurring_core.sql`), its patch reads only `label`/`template`/`interval_count`/
 * `due_offset_days`/`end_date`/`note` -- never `kind`, `frequency` or `start_date` -- so those three are
 * fixed at creation and rendered read-only (not even submitted) in edit mode, while every template header
 * field (customer/vendor/account/payee, notes, terms, currency, ...) stays editable, since it lives inside
 * the wholesale-replaced `template`. `due_offset_days` is meaningless for an `expense` rule (the migration's
 * own comment: "due_offset_days is meaningless for an expense... the occurrence date is used as-is"), so
 * that input is hidden rather than shown-and-ignored for that kind.
 */

const KIND_OPTIONS = Object.entries(RECURRING_KIND_LABELS) as [RecurringKind, string][];
const FREQUENCY_OPTIONS = Object.entries(RECURRING_FREQUENCY_LABELS) as [
  RecurringFrequency,
  string,
][];

function templateField(template: unknown, key: string): string {
  if (!template || typeof template !== "object") return "";
  const value = (template as Record<string, unknown>)[key];
  if (value == null) return "";
  return typeof value === "string" ? value : String(value);
}

function templateLines(template: unknown): Record<string, unknown>[] {
  if (!template || typeof template !== "object") return [];
  const lines = (template as Record<string, unknown>).lines;
  return Array.isArray(lines) ? (lines as Record<string, unknown>[]) : [];
}

export function RecurringRuleForm({
  mode,
  entityId,
  entity,
  rule,
  customers,
  vendors,
  accounts,
  channels,
  categories,
}: {
  mode: "create" | "edit";
  entityId: string;
  entity: string | undefined;
  /** Required for `mode: "edit"`. */
  rule?: RecurringRuleRow;
  customers: readonly ContactPickerRow[];
  vendors: readonly ContactPickerRow[];
  accounts: readonly FinancialAccountPickerRow[];
  channels: readonly PaymentChannelPickerRow[];
  categories: readonly CategoryRow[];
}) {
  const [state, action, pending] = useActionState(
    mode === "create" ? createRecurringRuleAction : updateRecurringRuleAction,
    idlePlanningActionState,
  );
  const [kind, setKind] = useState<RecurringKind>(rule?.kind ?? "invoice");
  const [frequency, setFrequency] = useState<RecurringFrequency | "">(rule?.frequency ?? "");
  const [rows, setRows] = useState<RecurringLineRow[]>(() =>
    buildInitialRecurringLines(templateLines(rule?.template)),
  );
  const template = rule?.template;
  const today = new Date().toISOString().slice(0, 10);
  const submitLabel = mode === "create" ? "Buat Aturan Berulang" : "Simpan Perubahan";
  const pendingLabel = mode === "create" ? "Membuat…" : "Menyimpan…";
  const intervalHint =
    frequency === "weekly"
      ? "kelipatan minggu"
      : frequency === "custom_days"
        ? "jumlah hari"
        : frequency === "monthly"
          ? "kelipatan bulan"
          : "kelipatan sesuai frekuensi";

  return (
    <form action={action} className="record-form-wide">
      <input type="hidden" name="entity_id" value={entityId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      {mode === "edit" && rule ? (
        <>
          <input type="hidden" name="rule_id" value={rule.id} />
          <input type="hidden" name="expected_version" value={rule.version} />
        </>
      ) : null}
      <input type="hidden" name="kind" value={kind} />
      <input type="hidden" name="lines" value={buildRecurringLinesJson(rows, kind)} />

      <label>
        Jenis Template
        {mode === "create" ? (
          <select
            value={kind}
            onChange={(event) => setKind(event.target.value as RecurringKind)}
            required
          >
            {KIND_OPTIONS.map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        ) : (
          <input type="text" value={RECURRING_KIND_LABELS[kind]} disabled readOnly />
        )}
      </label>

      <label>
        Nama Aturan
        <input
          type="text"
          name="label"
          required
          minLength={2}
          maxLength={200}
          defaultValue={rule?.label ?? ""}
        />
      </label>

      <label>
        Frekuensi
        {mode === "create" ? (
          <select
            name="frequency"
            required
            value={frequency}
            onChange={(event) => setFrequency(event.target.value as RecurringFrequency)}
          >
            <option value="" disabled>
              Pilih frekuensi…
            </option>
            {FREQUENCY_OPTIONS.map(([value, label]) => (
              <option key={value} value={value}>
                {label}
              </option>
            ))}
          </select>
        ) : (
          <input
            type="text"
            value={rule ? RECURRING_FREQUENCY_LABELS[rule.frequency] : ""}
            disabled
            readOnly
          />
        )}
      </label>

      <label>
        Interval ({intervalHint})
        <input
          type="number"
          name="interval_count"
          min={1}
          max={365}
          step={1}
          defaultValue={rule?.interval_count ?? 1}
        />
      </label>

      {kind !== "expense" ? (
        <label>
          Batas Waktu Jatuh Tempo (hari setelah dibuat)
          <input
            type="number"
            name="due_offset_days"
            min={0}
            max={365}
            step={1}
            defaultValue={rule?.due_offset_days ?? 0}
          />
        </label>
      ) : null}

      <label>
        Tanggal Mulai
        {mode === "create" ? (
          <input type="date" name="start_date" defaultValue={today} required />
        ) : (
          <input type="text" value={rule?.start_date ?? ""} disabled readOnly />
        )}
      </label>

      <label>
        Tanggal Berakhir (opsional)
        <input type="date" name="end_date" defaultValue={rule?.end_date ?? ""} />
      </label>

      <label>
        Catatan Aturan (opsional)
        <textarea name="note" maxLength={1000} defaultValue={rule?.note ?? ""} />
      </label>

      <fieldset className="record-form-section">
        <legend>{RECURRING_KIND_LABELS[kind]}</legend>

        {kind === "invoice" ? (
          <>
            <label>
              Pelanggan
              <select
                name="customer_id"
                required
                defaultValue={templateField(template, "customer_id")}
              >
                <option value="" disabled>
                  Pilih pelanggan…
                </option>
                {customers.map((customer) => (
                  <option key={customer.id} value={customer.id}>
                    {customer.display_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Akun Pembayaran (opsional)
              <select
                name="payment_account_id"
                defaultValue={templateField(template, "payment_account_id")}
              >
                <option value="">Tidak ditentukan</option>
                {accounts.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name} ({account.currency})
                  </option>
                ))}
              </select>
            </label>
            <label>
              Kanal Pembayaran (opsional)
              <select
                name="payment_channel_id"
                defaultValue={templateField(template, "payment_channel_id")}
              >
                <option value="">Tidak ditentukan</option>
                {channels.map((channel) => (
                  <option key={channel.id} value={channel.id}>
                    {channel.name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Mata Uang (opsional, 3 huruf)
              <input
                type="text"
                name="currency"
                maxLength={3}
                defaultValue={templateField(template, "currency")}
                placeholder="Mengikuti mata uang dasar Entity"
              />
            </label>
            <label>
              Syarat Pembayaran (opsional)
              <textarea
                name="terms"
                maxLength={4000}
                defaultValue={templateField(template, "terms")}
              />
            </label>
            <label>
              Catatan Faktur (opsional)
              <textarea
                name="notes"
                maxLength={2000}
                defaultValue={templateField(template, "notes")}
              />
            </label>
            <label>
              Catatan Internal (opsional)
              <textarea
                name="internal_note"
                maxLength={2000}
                defaultValue={templateField(template, "internal_note")}
              />
            </label>
          </>
        ) : null}

        {kind === "bill" ? (
          <>
            <label>
              Vendor
              <select name="vendor_id" required defaultValue={templateField(template, "vendor_id")}>
                <option value="" disabled>
                  Pilih vendor…
                </option>
                {vendors.map((vendor) => (
                  <option key={vendor.id} value={vendor.id}>
                    {vendor.display_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Referensi Vendor (opsional)
              <input
                type="text"
                name="vendor_reference"
                maxLength={100}
                defaultValue={templateField(template, "vendor_reference")}
              />
            </label>
            <label>
              Mata Uang (opsional, 3 huruf)
              <input
                type="text"
                name="currency"
                maxLength={3}
                defaultValue={templateField(template, "currency")}
                placeholder="Mengikuti mata uang dasar Entity"
              />
            </label>
            <label>
              Catatan Tagihan (opsional)
              <textarea
                name="notes"
                maxLength={2000}
                defaultValue={templateField(template, "notes")}
              />
            </label>
            <label>
              Catatan Internal (opsional)
              <textarea
                name="internal_note"
                maxLength={2000}
                defaultValue={templateField(template, "internal_note")}
              />
            </label>
          </>
        ) : null}

        {kind === "expense" ? (
          <>
            <label>
              Akun Pembayar
              <select
                name="account_id"
                required
                defaultValue={templateField(template, "account_id")}
              >
                <option value="" disabled>
                  Pilih akun…
                </option>
                {accounts.map((account) => (
                  <option key={account.id} value={account.id}>
                    {account.name} ({account.currency})
                  </option>
                ))}
              </select>
            </label>
            <label>
              Penerima (vendor, opsional jika nama diisi)
              <select name="payee_id" defaultValue={templateField(template, "payee_id")}>
                <option value="">Tidak ditentukan</option>
                {vendors.map((vendor) => (
                  <option key={vendor.id} value={vendor.id}>
                    {vendor.display_name}
                  </option>
                ))}
              </select>
            </label>
            <label>
              Nama Penerima (opsional jika vendor dipilih)
              <input
                type="text"
                name="payee_name"
                maxLength={200}
                defaultValue={templateField(template, "payee_name")}
              />
            </label>
            <label>
              Referensi Kuitansi (opsional)
              <input
                type="text"
                name="receipt_reference"
                maxLength={100}
                defaultValue={templateField(template, "receipt_reference")}
              />
            </label>
            <label>
              Catatan Pengeluaran (opsional)
              <textarea
                name="notes"
                maxLength={2000}
                defaultValue={templateField(template, "notes")}
              />
            </label>
            <label>
              Catatan Internal (opsional)
              <textarea
                name="internal_note"
                maxLength={2000}
                defaultValue={templateField(template, "internal_note")}
              />
            </label>
          </>
        ) : null}

        <RecurringLinesEditor kind={kind} categories={categories} rows={rows} onChange={setRows} />
      </fieldset>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? pendingLabel : submitLabel}
      </button>
    </form>
  );
}
