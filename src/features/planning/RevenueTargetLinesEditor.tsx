"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import type { RevenueTargetLineRow } from "@/schemas/planning";
import { setRevenueTargetLinesAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";
import { formatMonthLabel } from "./format";
import { MoneyInput } from "@/features/shared/MoneyInput";

/**
 * Revenue Target "set lines" editor (P13 Part 3h, fifth increment, Step 09 §18). Unlike Budget lines,
 * revenue target lines carry no category (Step 01 #23 names none), so this is a flat month -> amount list
 * rather than a 2D grid: the row set is fixed by the target's own `start_date`/`end_date` range (via
 * `monthRangeInclusive`, shared with `BudgetLinesEditor`), never user-added/removed. Money cells share the
 * same plain decimal-text convention as `BudgetLinesEditor`'s own cells; `set_revenue_target_lines`
 * wholesale-replaces the whole line set, so every month is always resubmitted (a blank cell simply omits
 * that month's line, the same "leave it out means no line" reading `BudgetLinesEditor` uses).
 */
export function RevenueTargetLinesEditor({
  targetId,
  months,
  existingLines,
  expectedVersion,
  currency,
}: {
  targetId: string;
  months: readonly string[];
  existingLines: readonly RevenueTargetLineRow[];
  expectedVersion: number;
  currency: string;
}) {
  const [state, action, pending] = useActionState(
    setRevenueTargetLinesAction,
    idlePlanningActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [amounts, setAmounts] = useState<Record<string, string>>(() =>
    Object.fromEntries(existingLines.map((line) => [line.period_month, line.target_amount])),
  );

  const linesJson = JSON.stringify(
    months.flatMap((month) => {
      const amount = (amounts[month] ?? "").trim();
      return amount === "" ? [] : [{ period_month: month, target_amount: amount }];
    }),
  );

  return (
    <form {...actionForm} className="plan-lines-editor">
      <input type="hidden" name="target_id" value={targetId} />
      <input type="hidden" name="expected_version" value={expectedVersion} />
      <input type="hidden" name="lines" value={linesJson} />

      <p className="hint">Jumlah dalam {currency}. Bulan kosong tidak akan disimpan.</p>

      <div className="plan-lines-table-wrap">
        <table className="record-table plan-lines-table">
          <thead>
            <tr>
              <th scope="col">Bulan</th>
              <th scope="col" className="num">
                Target
              </th>
            </tr>
          </thead>
          <tbody>
            {months.map((month) => (
              <tr key={month}>
                <td>{formatMonthLabel(month)}</td>
                <td className="num">
                  <MoneyInput
                    value={amounts[month] ?? ""}
                    onValueChange={(amount) => setAmounts((prev) => ({ ...prev, [month]: amount }))}
                    placeholder="0"
                  />
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
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan Baris Target Pendapatan"}
        </button>
      </div>
    </form>
  );
}
