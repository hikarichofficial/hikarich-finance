"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useRef, useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import type { CategoryRow } from "@/schemas/categories";
import type { RevenueTargetLineRow } from "@/schemas/planning";
import { setRevenueTargetLinesAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";
import { formatMonthLabel } from "./format";
import { MoneyInput } from "@/features/shared/MoneyInput";
import { Picker } from "@/features/shared/Picker";

/**
 * Revenue Target "set lines" editor (Step 09 §18; decision 399 made it a grid).
 *
 * It used to be a flat month -> amount list, because a revenue target carried no category. The OWNER asked
 * for the target to be breakable down per revenue category, so this is now the same shape as
 * `BudgetLinesEditor`: months are fixed columns (the target's own date range), rows are what is being
 * targeted.
 *
 * The first row is always there and is the Entity's whole revenue -- the only thing a target could mean
 * before, so an existing target opens unchanged. Category rows are added and removed underneath it, and
 * either half can be left empty: a target can be the total alone, categories alone, or both. The parts are
 * not forced to add up to the total; a plan that covers two product lines out of five is normal, and the
 * report prints the total row and the category rows separately rather than adding them together.
 *
 * `set_revenue_target_lines` replaces the whole line set on every call, so this always submits the complete
 * desired state; an empty cell simply omits that line.
 */

interface GridRow {
  key: string;
  /** "" on the Entity-total row, which is also the only row without a Picker. */
  categoryId: string;
  amounts: Record<string, string>;
}

const TOTAL_ROW_KEY = "entity-total";

function buildInitialRows(existingLines: readonly RevenueTargetLineRow[]): GridRow[] {
  const total: GridRow = { key: TOTAL_ROW_KEY, categoryId: "", amounts: {} };
  const byCategory = new Map<string, GridRow>();
  for (const line of existingLines) {
    if (line.category_id === null) {
      total.amounts[line.period_month] = line.target_amount;
      continue;
    }
    const row = byCategory.get(line.category_id) ?? {
      key: line.category_id,
      categoryId: line.category_id,
      amounts: {},
    };
    row.amounts[line.period_month] = line.target_amount;
    byCategory.set(line.category_id, row);
  }
  return [total, ...byCategory.values()];
}

function buildLinesJson(rows: readonly GridRow[], months: readonly string[]): string {
  return JSON.stringify(
    rows.flatMap((row) => {
      const isTotal = row.key === TOTAL_ROW_KEY;
      if (!isTotal && !row.categoryId) return [];
      return months.flatMap((month) => {
        const amount = (row.amounts[month] ?? "").trim();
        if (amount === "") return [];
        return [
          isTotal
            ? { period_month: month, target_amount: amount }
            : { period_month: month, target_amount: amount, category_id: row.categoryId },
        ];
      });
    }),
  );
}

export function RevenueTargetLinesEditor({
  targetId,
  months,
  categories,
  existingLines,
  expectedVersion,
  currency,
}: {
  targetId: string;
  months: readonly string[];
  /** This Entity's revenue categories; a revenue target can only be split by those. */
  categories: readonly CategoryRow[];
  existingLines: readonly RevenueTargetLineRow[];
  expectedVersion: number;
  currency: string;
}) {
  const [state, action, pending] = useActionState(
    setRevenueTargetLinesAction,
    idlePlanningActionState,
  );
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
      <input type="hidden" name="target_id" value={targetId} />
      <input type="hidden" name="expected_version" value={expectedVersion} />
      <input type="hidden" name="lines" value={buildLinesJson(rows, months)} />

      <p className="hint">
        Jumlah dalam {currency}. Sel kosong tidak akan disimpan. Baris pertama adalah target seluruh
        Entitas; di bawahnya bisa ditambahkan target per kategori pendapatan. Keduanya tidak harus
        sama besar — laporannya menampilkan masing-masing, tidak dijumlahkan.
      </p>

      <div className="plan-lines-table-wrap">
        <table className="record-table plan-lines-table">
          <thead>
            <tr>
              <th scope="col">Target</th>
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
                  {row.key === TOTAL_ROW_KEY ? (
                    <strong>Seluruh Entitas</strong>
                  ) : (
                    <Picker
                      label="Kategori Pendapatan"
                      name={`category_${row.key}`}
                      items={availableCategoriesFor(row.key).map((category) => ({
                        id: category.id,
                        label: category.name,
                      }))}
                      noun="kategori"
                      value={row.categoryId}
                      onChange={(id) => setCategory(row.key, id)}
                    />
                  )}
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
                  {row.key === TOTAL_ROW_KEY ? null : (
                    <button type="button" className="btn-ghost" onClick={() => removeRow(row.key)}>
                      Hapus
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <div className="plan-lines-editor-actions">
        <button type="button" className="btn-secondary" onClick={addRow} disabled={!canAddRow}>
          + Tambah Kategori Pendapatan
        </button>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Baris Target Pendapatan"}
        </button>
      </div>
    </form>
  );
}
