"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import {
  checkOpeningLines,
  type OpeningAccountOption,
  type OpeningLineDraft,
} from "@/domain/accounting/openingBalances";
import { formatMoney } from "@/domain/money/format";
import { postOpeningBalancesAction } from "./openingBalanceActions";
import { idleOpeningActionState } from "./openingBalanceActionsState";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { Picker } from "@/features/shared/Picker";

/**
 * Post Opening Balances (Step 15 §24, decision 245): a cutover date plus a debit/credit grid over
 * balance-sheet accounts. The difference between total debit and credit is shown live: the database books
 * it to the opening-balance clearing account, which must later be reconciled before Completion.
 *
 * The account cell is a Picker, not a dropdown (OWNER, 11 October 2026; decision 403). The chart of
 * accounts is the longest list in the app -- 114 accounts for a company -- so scrolling to find "Modal
 * Disetor" was the slowest part of the slowest screen. An account that may not be posted to by hand is
 * left out of the list rather than offered and refused, which the dropdown could do with `disabled` and a
 * Picker cannot; the hint that explained why is kept on the ones that remain.
 */

function emptyRow(n: number): OpeningLineDraft {
  return { key: `row-${n}`, account_id: "", debit: "", credit: "", description: "" };
}

export function OpeningBalanceForm({
  options,
  baseCurrency,
  entity,
}: {
  options: readonly OpeningAccountOption[];
  baseCurrency: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(
    postOpeningBalancesAction,
    idleOpeningActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<OpeningLineDraft[]>([emptyRow(1), emptyRow(2)]);
  const [seq, setSeq] = useState(3);
  // After a successful posting the grid is emptied so the same numbers cannot be posted twice by accident.
  const [clearedFor, setClearedFor] = useState<unknown>(null);
  if (state.status === "ok" && clearedFor !== state) {
    setClearedFor(state);
    setRows([emptyRow(seq), emptyRow(seq + 1)]);
    setSeq(seq + 2);
  }
  const check = checkOpeningLines(rows);

  function update(key: string, field: keyof OpeningLineDraft, value: string) {
    setRows((current) => current.map((r) => (r.key === key ? { ...r, [field]: value } : r)));
  }

  return (
    <form {...actionForm} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={JSON.stringify(check.lines)} />
      <label>
        Tanggal Cutover
        <input type="date" name="cutover_date" required />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={500} />
      </label>

      <table className="record-table plan-lines-table">
        <thead>
          <tr>
            <th scope="col">Akun</th>
            <th scope="col" className="num">
              Debit
            </th>
            <th scope="col" className="num">
              Kredit
            </th>
            <th scope="col">Keterangan</th>
            <th scope="col">Hapus</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.key}>
              <td>
                <Picker
                  label="Akun"
                  name={`opening-account-${row.key}`}
                  noun="akun"
                  optional
                  items={options
                    .filter(({ disabled }) => !disabled)
                    .map(({ account: a, hint }) => ({
                      id: a.id,
                      label: `${a.code} · ${a.name}${hint ? ` (${hint})` : ""}`,
                    }))}
                  value={row.account_id}
                  onChange={(id) => update(row.key, "account_id", id)}
                />
              </td>
              <td className="num">
                <MoneyInput
                  aria-label="Debit"
                  value={row.debit}
                  onValueChange={(debit) => update(row.key, "debit", debit)}
                />
              </td>
              <td className="num">
                <MoneyInput
                  aria-label="Kredit"
                  value={row.credit}
                  onValueChange={(credit) => update(row.key, "credit", credit)}
                />
              </td>
              <td>
                <input
                  aria-label="Keterangan"
                  maxLength={500}
                  value={row.description}
                  onChange={(e) => update(row.key, "description", e.target.value)}
                />
              </td>
              <td>
                <button
                  type="button"
                  className="btn-ghost"
                  onClick={() => setRows((current) => current.filter((r) => r.key !== row.key))}
                  disabled={rows.length <= 1}
                >
                  Hapus
                </button>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr>
            <th scope="row">Total</th>
            <td className="num">{formatMoney(check.totalDebit, baseCurrency)}</td>
            <td className="num">{formatMoney(check.totalCredit, baseCurrency)}</td>
            <td colSpan={2}>
              Selisih ke akun penampung: {formatMoney(check.difference, baseCurrency)}
            </td>
          </tr>
        </tfoot>
      </table>
      <button
        type="button"
        className="btn-secondary"
        onClick={() => {
          setRows((current) => [...current, emptyRow(seq)]);
          setSeq((n) => n + 1);
        }}
      >
        Tambah Baris
      </button>

      {check.problems.length > 0 ? (
        <ul className="hint">
          {check.problems.map((problem) => (
            <li key={problem}>{problem}</li>
          ))}
        </ul>
      ) : null}
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending || check.problems.length > 0}>
        {pending ? "Memposting…" : "Posting Saldo Awal"}
      </button>
    </form>
  );
}
