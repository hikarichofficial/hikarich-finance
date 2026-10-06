"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useRef, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import type { CategoryRow } from "@/schemas/categories";
import type { BudgetLineRow } from "@/schemas/planning";
import { setBudgetLinesAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";
import { formatMonthLabel } from "./format";
import { MoneyInput } from "@/features/shared/MoneyInput";

/**
 * Budget "set lines" editable grid (P13 Part 3h, fifth increment, Step 09 §18: "period-based editable
 * planning tables"). Categories are rows (user-added/removed, a genuine 2D grid), months (derived by the
 * page from the budget's own `start_date`/`end_date` via `monthRangeInclusive`) are fixed columns.
 * `set_budget_lines` wholesale-replaces the entire line set on every call, so this always submits the
 * complete desired state, pre-populated from `existingLines` -- never a diff/patch. Row/cell edits are kept
 * in local state and serialized into one hidden `lines` JSON field just before submit (`parseLinesJson` on
 * the action side), rather than a dynamic `amount__<categoryId>__<month>` field set -- simpler to build and
 * to test. A category already chosen in another row is not offered again, matching the RPC's own
 * (category_id, period_month) uniqueness. Money cells are plain decimal-text inputs, the same
 * `inputMode="decimal"` convention `TransferForm`'s own amount fields use -- no currency symbol inline, only
 * a hint line naming the Entity's base currency.
 */

interface GridRow {
  key: string;
  categoryId: string;
  amounts: Record<string, string>;
}

function buildInitialRows(existingLines: readonly BudgetLineRow[]): GridRow[] {
  const byCategory = new Map<string, GridRow>();
  for (const line of existingLines) {
    const row = byCategory.get(line.category_id) ?? {
      key: line.category_id,
      categoryId: line.category_id,
      amounts: {},
    };
    row.amounts[line.period_month] = line.budgeted_amount;
    byCategory.set(line.category_id, row);
  }
  return Array.from(byCategory.values());
}

function buildLinesJson(rows: readonly GridRow[], months: readonly string[]): string {
  return JSON.stringify(
    rows.flatMap((row) => {
      if (!row.categoryId) return [];
      return months.flatMap((month) => {
        const amount = (row.amounts[month] ?? "").trim();
        return amount === ""
          ? []
          : [{ category_id: row.categoryId, period_month: month, budgeted_amount: amount }];
      });
    }),
  );
}

export function BudgetLinesEditor({
  budgetId,
  months,
  categories,
  existingLines,
  expectedVersion,
  currency,
}: {
  budgetId: string;
  months: readonly string[];
  categories: readonly CategoryRow[];
  existingLines: readonly BudgetLineRow[];
  expectedVersion: number;
  currency: string;
}) {
  const [state, action, pending] = useActionState(setBudgetLinesAction, idlePlanningActionState);
  const actionForm = usePreservingForm(action, state);
  const [rows, setRows] = useState<GridRow[]>(() => buildInitialRows(existingLines));
  const nextRowSeq = useRef(0);

  function addRow() {
    nextRowSeq.current += 1;
    setRows((prev) => [...prev, { key: `new-${nextRowSeq.current}`, categoryId: "", amounts: {} }]);
  }

  function removeRow(key: string) {
    setRows((prev) => prev.filter((row) => row.key !== key));
  }

  function setCategory(key: string, categoryId: string) {
    setRows((prev) => prev.map((row) => (row.key === key ? { ...row, categoryId } : row)));
  }

  function setAmount(key: string, month: string, value: string) {
    setRows((prev) =>
      prev.map((row) =>
        row.key === key ? { ...row, amounts: { ...row.amounts, [month]: value } } : row,
      ),
    );
  }

  function availableCategoriesFor(key: string): readonly CategoryRow[] {
    const usedElsewhere = new Set(
      rows.filter((row) => row.key !== key && row.categoryId).map((row) => row.categoryId),
    );
    return categories.filter((category) => !usedElsewhere.has(category.id));
  }

  const usedCategoryIds = new Set(rows.map((row) => row.categoryId).filter(Boolean));
  const canAddRow = categories.some((category) => !usedCategoryIds.has(category.id));

  return (
    <form {...actionForm} className="plan-lines-editor">
      <input type="hidden" name="budget_id" value={budgetId} />
      <input type="hidden" name="expected_version" value={expectedVersion} />
      <input type="hidden" name="lines" value={buildLinesJson(rows, months)} />

      <p className="hint">Jumlah dalam {currency}. Baris kosong tidak akan disimpan.</p>

      {rows.length === 0 ? (
        <p className="dashboard-empty">Belum ada baris. Tambahkan kategori untuk mulai mengisi.</p>
      ) : (
        <div className="plan-lines-table-wrap">
          <table className="record-table plan-lines-table">
            <thead>
              <tr>
                <th scope="col">Kategori</th>
                {months.map((month) => (
                  <th key={month} scope="col" className="num">
                    {formatMonthLabel(month)}
                  </th>
                ))}
                <th scope="col" aria-label="Hapus baris" />
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <tr key={row.key}>
                  <td>
                    <select
                      value={row.categoryId}
                      onChange={(event) => setCategory(row.key, event.target.value)}
                      required
                    >
                      <option value="" disabled>
                        Pilih kategori…
                      </option>
                      {availableCategoriesFor(row.key).map((category) => (
                        <option key={category.id} value={category.id}>
                          {category.name}
                        </option>
                      ))}
                    </select>
                  </td>
                  {months.map((month) => (
                    <td key={month} className="num">
                      <MoneyInput
                        value={row.amounts[month] ?? ""}
                        onValueChange={(amount) => setAmount(row.key, month, amount)}
                        placeholder="0"
                      />
                    </td>
                  ))}
                  <td>
                    <button type="button" className="btn-ghost" onClick={() => removeRow(row.key)}>
                      Hapus
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <div className="plan-lines-editor-actions">
        <button type="button" className="btn-secondary" onClick={addRow} disabled={!canAddRow}>
          + Tambah Kategori
        </button>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Baris Anggaran"}
        </button>
      </div>
    </form>
  );
}
