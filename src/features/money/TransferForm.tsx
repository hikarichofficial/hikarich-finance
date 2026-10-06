"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import type { MoneyControlRow } from "@/schemas/money";
import { createTransferAction } from "./transferActions";
import { idleTransferFormState } from "./transferActionsState";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { SuggestTextInput } from "@/features/shared/SuggestTextInput";
import { todayInBusinessZone } from "@/lib/time";

/**
 * Transfer create form (P13 Part 3c, Step 09 §13: "Transfer form clearly distinguishes same-Entity transfer
 * from prohibited PT<->Personal generic transfer"). The account pickers only ever list the active Entity's
 * own active accounts (`accounts`, already fetched by the page from `money_control`), so a cross-Entity or
 * PT<->Personal pair is structurally impossible to even select here -- the same boundary `create_transfer`
 * itself enforces server-side (Step 03 §8), made visible rather than merely relied upon. `amount_in`/
 * `rate_out`/`rate_in` are optional and only needed when the two accounts use different currencies (the RPC
 * defaults `amount_in` to `amount_out` for a same-currency pair) -- kept as plain, always-visible fields with
 * explicit helper text rather than a dynamic show/hide, matching this codebase's minimal-JS bias.
 */
export function TransferForm({
  accounts,
  entityId,
  entity,
  canConfirmOnCreate,
  descriptionSuggestions = [],
}: {
  accounts: readonly MoneyControlRow[];
  entityId: string;
  entity: string | undefined;
  canConfirmOnCreate: boolean;
  /** Descriptions used on earlier transfers, newest first, offered while typing. */
  descriptionSuggestions?: readonly string[];
}) {
  const [state, action, pending] = useActionState(createTransferAction, idleTransferFormState);
  const actionForm = usePreservingForm(action, state);
  const today = todayInBusinessZone();
  const active = accounts.filter((a) => a.is_active);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity_id" value={entityId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}

      <label>
        Dari Akun
        <select name="from_account_id" required defaultValue="">
          <option value="" disabled>
            Pilih akun sumber…
          </option>
          {active.map((a) => (
            <option key={a.financial_account_id} value={a.financial_account_id}>
              {a.name} ({a.currency})
            </option>
          ))}
        </select>
      </label>

      <label>
        Ke Akun
        <select name="to_account_id" required defaultValue="">
          <option value="" disabled>
            Pilih akun tujuan…
          </option>
          {active.map((a) => (
            <option key={a.financial_account_id} value={a.financial_account_id}>
              {a.name} ({a.currency})
            </option>
          ))}
        </select>
      </label>

      <label>
        Tanggal Transfer
        <input type="date" name="transfer_date" defaultValue={today} required />
      </label>

      <label>
        Jumlah Dikirim
        <MoneyInput name="amount_out" required placeholder="0" />
      </label>

      <label>
        Biaya Bank (opsional)
        <MoneyInput name="fee" placeholder="0" />
      </label>

      <p className="hint">
        Isi field di bawah ini hanya jika mata uang akun sumber dan tujuan berbeda.
      </p>
      <label>
        Jumlah Diterima (opsional)
        <MoneyInput name="amount_in" placeholder="Samakan dengan Jumlah Dikirim" />
      </label>
      <label>
        Kurs Sumber (opsional)
        <input type="text" inputMode="decimal" name="rate_out" />
      </label>
      <label>
        Kurs Tujuan (opsional)
        <input type="text" inputMode="decimal" name="rate_in" />
      </label>

      <SuggestTextInput
        label="Deskripsi (opsional)"
        name="description"
        suggestions={descriptionSuggestions}
        noun="deskripsi"
        maxLength={500}
      />
      <label>
        Referensi (opsional)
        <input type="text" name="reference" maxLength={120} />
      </label>

      {canConfirmOnCreate ? (
        <label className="checkbox-field">
          <input type="checkbox" name="confirm" />
          Konfirmasi transfer ini sekarang juga (langsung memposting jurnal)
        </label>
      ) : (
        <p className="hint">
          Transfer ini disimpan sebagai draf dan menunggu konfirmasi dari pihak yang berwenang.
        </p>
      )}

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan Transfer"}
      </button>
    </form>
  );
}
