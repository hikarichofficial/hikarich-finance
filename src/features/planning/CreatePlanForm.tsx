"use client";

import { useActionState } from "react";
import { PLAN_PERIOD_TYPE_LABELS, type PlanPeriodType } from "@/domain/planning/planning";
import { createBudgetAction, createRevenueTargetAction, idlePlanningActionState } from "./actions";

/**
 * Create-shell form for a Budget or Revenue Target (P13 Part 3h, fifth increment, Step 09 §18). The two
 * create RPCs (`create_budget`/`create_revenue_target`) take the identical shape --
 * name/period_type/start_date/end_date/fiscal_year/note -- so one component covers both, parameterized by
 * `kind`, the same "genuinely shared, not just similarly shaped" reasoning decision 184 already applied to
 * `budgetList.ts`'s badge/filter/eligibility helpers. This only creates the draft shell; the "set lines"
 * grid that fills it in lives on the resulting record's own Detail page (`BudgetLinesEditor`/
 * `RevenueTargetLinesEditor`), reached by this form's own `redirect()`-on-success.
 */
const PERIOD_TYPE_OPTIONS = Object.entries(PLAN_PERIOD_TYPE_LABELS) as [PlanPeriodType, string][];

export function CreatePlanForm({
  kind,
  entityId,
  entity,
}: {
  kind: "budget" | "revenue_target";
  entityId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(
    kind === "budget" ? createBudgetAction : createRevenueTargetAction,
    idlePlanningActionState,
  );
  const today = new Date().toISOString().slice(0, 10);
  const submitLabel = kind === "budget" ? "Simpan Anggaran" : "Simpan Target Pendapatan";

  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity_id" value={entityId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}

      <label>
        Nama
        <input type="text" name="name" required minLength={2} maxLength={200} />
      </label>

      <label>
        Jenis Periode
        <select name="period_type" required defaultValue="">
          <option value="" disabled>
            Pilih jenis periode…
          </option>
          {PERIOD_TYPE_OPTIONS.map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>

      <label>
        Tanggal Mulai
        <input type="date" name="start_date" defaultValue={today} required />
      </label>

      <label>
        Tanggal Akhir
        <input type="date" name="end_date" required />
      </label>

      <label>
        Tahun Fiskal (opsional)
        <input type="number" name="fiscal_year" min={2000} max={2100} step={1} />
      </label>

      <label>
        Catatan (opsional)
        <textarea name="note" maxLength={1000} />
      </label>

      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}

      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : submitLabel}
      </button>
    </form>
  );
}
