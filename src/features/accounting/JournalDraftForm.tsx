"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import { Decimal, sumDecimals } from "@/domain/money/decimal";
import { createJournalDraftAction, type JournalDraftState } from "./journalDraftActions";

const IDLE: JournalDraftState = { status: "idle" };

export interface JournalAccountOption {
  id: string;
  label: string;
}

interface JournalLineRowState {
  key: string;
  account_id: string;
  debit: string;
  credit: string;
  description: string;
}

function newRow(seq: number): JournalLineRowState {
  return { key: `row-${seq}`, account_id: "", debit: "", credit: "", description: "" };
}

function amount(value: string): Decimal {
  const trimmed = value.trim();
  if (trimmed === "") return Decimal.zero();
  return Decimal.tryParse(trimmed) ?? Decimal.zero();
}

/** Rows without an account or without any amount are left out; only the side that is filled is sent. */
function buildLinesJson(rows: readonly JournalLineRowState[]): string {
  return JSON.stringify(
    rows.flatMap((row) => {
      const debit = row.debit.trim();
      const credit = row.credit.trim();
      if (row.account_id === "" || (debit === "" && credit === "")) return [];
      const line: Record<string, string> = { account_id: row.account_id };
      if (debit !== "" && !amount(debit).isZero()) line.debit = debit;
      if (credit !== "" && !amount(credit).isZero()) line.credit = credit;
      if (row.description.trim() !== "") line.description = row.description.trim();
      return [line];
    }),
  );
}

/**
 * Jurnal Manual (Step 09 §14): a manual or adjusting journal saved as a DRAFT through
 * `create_journal_draft`. Each line names one account and exactly one side (debit or credit); the running
 * totals show whether the journal balances before it is saved. The database checks balance, the period and
 * protected accounts again; posting is a separate step on Journal Detail.
 */
export function JournalDraftForm({
  accounts,
  entity,
  today,
  canOverride,
}: {
  accounts: readonly JournalAccountOption[];
  entity: string | undefined;
  today: string;
  canOverride: boolean;
}) {
  const [state, action, pending] = useActionState(createJournalDraftAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<JournalLineRowState[]>([newRow(1), newRow(2)]);
  const [seq, setSeq] = useState(3);

  function updateRow(key: string, patch: Partial<JournalLineRowState>) {
    setRows(rows.map((row) => (row.key === key ? { ...row, ...patch } : row)));
  }

  function addRow() {
    setRows([...rows, newRow(seq)]);
    setSeq(seq + 1);
  }

  const totalDebit = sumDecimals(rows.map((row) => amount(row.debit)));
  const totalCredit = sumDecimals(rows.map((row) => amount(row.credit)));
  const balanced = totalDebit.eq(totalCredit) && !totalDebit.isZero();

  return (
    <form {...actionForm} className="record-form record-form-wide">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="lines" value={buildLinesJson(rows)} />
      <label>
        Jenis Jurnal
        <select name="entry_type" defaultValue="manual">
          <option value="manual">Jurnal manual</option>
          <option value="adjusting">Jurnal penyesuaian</option>
        </select>
      </label>
      <label>
        Tanggal
        <input type="date" name="entry_date" required defaultValue={today} />
      </label>
      <label>
        Penjelasan (jurnal penyesuaian minimal 10 karakter)
        <input name="description" required maxLength={500} />
      </label>

      <div className="plan-lines-editor">
        <p className="hint">
          Tiap baris diisi satu sisi saja: debit atau kredit. Baris tanpa akun atau tanpa jumlah
          tidak disimpan.
        </p>
        <div className="plan-lines-table-wrap">
          <table className="record-table plan-lines-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Akun</th>
                <th scope="col" className="num">
                  Debit
                </th>
                <th scope="col" className="num">
                  Kredit
                </th>
                <th scope="col">Keterangan Baris</th>
                <th scope="col" aria-label="Hapus baris" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.key}>
                  <td>
                    <select
                      aria-label="Akun"
                      value={row.account_id}
                      onChange={(event) => updateRow(row.key, { account_id: event.target.value })}
                    >
                      <option value="">Pilih akun</option>
                      {accounts.map((account) => (
                        <option key={account.id} value={account.id}>
                          {account.label}
                        </option>
                      ))}
                    </select>
                  </td>
                  <td className="num" data-label="Debit">
                    <input
                      type="text"
                      inputMode="decimal"
                      value={row.debit}
                      onChange={(event) => updateRow(row.key, { debit: event.target.value })}
                      placeholder="0"
                    />
                  </td>
                  <td className="num" data-label="Kredit">
                    <input
                      type="text"
                      inputMode="decimal"
                      value={row.credit}
                      onChange={(event) => updateRow(row.key, { credit: event.target.value })}
                      placeholder="0"
                    />
                  </td>
                  <td data-label="Keterangan Baris">
                    <input
                      type="text"
                      maxLength={500}
                      value={row.description}
                      onChange={(event) => updateRow(row.key, { description: event.target.value })}
                      placeholder="Opsional"
                    />
                  </td>
                  <td>
                    <button
                      type="button"
                      className="btn-ghost"
                      onClick={() => setRows(rows.filter((other) => other.key !== row.key))}
                    >
                      Hapus
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <div className="plan-lines-editor-actions">
          <button type="button" className="btn-secondary" onClick={addRow}>
            + Tambah Baris
          </button>
        </div>
        <p className="hint">
          Total debit: {totalDebit.toString()} · Total kredit: {totalCredit.toString()} ·{" "}
          {balanced
            ? "Seimbang."
            : `Belum seimbang (selisih ${totalDebit.sub(totalCredit).abs().toString()}).`}
        </p>
      </div>

      {canOverride ? (
        <label>
          Alasan memakai akun yang dilindungi (opsional; kosongkan jika tidak perlu)
          <input name="override_reason" maxLength={500} />
        </label>
      ) : null}

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending || !balanced}>
        {pending ? "Menyimpan…" : "Simpan sebagai Draf"}
      </button>
    </form>
  );
}
