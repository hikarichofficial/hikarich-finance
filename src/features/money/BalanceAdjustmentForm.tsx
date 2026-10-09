"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import type { LedgerAccountRow } from "@/schemas/accounting";
import type { MoneyControlRow } from "@/schemas/money";
import { eligibleCounterAccounts } from "@/domain/money/balanceAdjustment";
import { recordBalanceAdjustmentAction } from "./balanceAdjustmentActions";
import { idleBalanceAdjustmentFormState } from "./balanceAdjustmentActionsState";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { todayInBusinessZone } from "@/lib/time";

/**
 * Balance Adjustment form ("Advanced Adjustments", Step 09 §14, decision 232): the account's balance is
 * corrected by a direct in/out movement against a chosen counter (ledger) account, posted immediately --
 * `record_balance_adjustment` has no draft/approval step of its own (Step 01 §28's "a difference is either
 * explained by outstanding items, corrected through an explicit balance adjustment, or accepted with a
 * written reason" -- reconciliation's own principle, this is that adjustment). Same plain, always-visible-
 * field shape `TransferForm.tsx` already established; the exchange-rate field is shown unconditionally with
 * helper text rather than a dynamic show/hide, matching that form's own minimal-JS bias.
 */
export function BalanceAdjustmentForm({
  accounts,
  ledgerAccounts,
  entityId,
  entity,
}: {
  accounts: readonly MoneyControlRow[];
  ledgerAccounts: readonly LedgerAccountRow[];
  entityId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(
    recordBalanceAdjustmentAction,
    idleBalanceAdjustmentFormState,
  );
  const actionForm = usePreservingForm(action, state);
  const today = todayInBusinessZone();
  const activeAccounts = accounts.filter((a) => a.is_active);
  const counterAccounts = eligibleCounterAccounts(ledgerAccounts);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity_id" value={entityId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}

      <label>
        Akun Kas/Bank
        <select name="account_id" required defaultValue="">
          <option value="" disabled>
            Pilih akun…
          </option>
          {activeAccounts.map((a) => (
            <option key={a.financial_account_id} value={a.financial_account_id}>
              {a.name} ({a.currency})
            </option>
          ))}
        </select>
      </label>

      <label>
        Arah
        <select name="direction" required defaultValue="in">
          <option value="in">Masuk (menambah saldo akun)</option>
          <option value="out">Keluar (mengurangi saldo akun)</option>
        </select>
      </label>

      <label>
        Tanggal
        <input type="date" name="movement_date" defaultValue={today} required />
      </label>

      <label>
        Jumlah
        <MoneyInput name="amount" required placeholder="0" />
      </label>

      <p className="hint">
        Halaman ini hanya untuk koreksi saldo (misalnya biaya admin bank). Untuk uang masuk dari
        penjualan, bunga, atau pendapatan lain, catat lewat Penjualan &gt; Catat Pendapatan agar
        pajaknya ikut terhitung.
      </p>

      <p className="hint">
        Isi kurs di bawah ini hanya jika mata uang akun berbeda dari mata uang dasar Entity.
      </p>
      <label>
        Kurs (opsional)
        <input type="text" inputMode="decimal" name="exchange_rate" />
      </label>

      <label>
        Akun Lawan
        <select name="counter_account_id" required defaultValue="">
          <option value="" disabled>
            Pilih akun…
          </option>
          {counterAccounts.map((a) => (
            <option key={a.id} value={a.id}>
              {a.code} — {a.name}
            </option>
          ))}
        </select>
      </label>

      <label>
        Alasan (minimal 10 karakter)
        <textarea name="reason" required minLength={10} maxLength={500} />
      </label>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Catat Penyesuaian"}
      </button>
    </form>
  );
}
