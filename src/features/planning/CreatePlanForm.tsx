"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import { PLAN_PERIOD_TYPE_LABELS, type PlanPeriodType } from "@/domain/planning/planning";
import { createBudgetAction, createRevenueTargetAction } from "./actions";
import { idlePlanningActionState } from "./actionsState";
import { todayInBusinessZone } from "@/lib/time";
import { SuggestTextInput } from "@/features/shared/SuggestTextInput";
import { planNameSuggestions } from "@/domain/planning/planNames";
import { useState } from "react";

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
  usedNames = [],
}: {
  kind: "budget" | "revenue_target";
  entityId: string;
  entity: string | undefined;
  /** Names this Entity has given its plans before, most recent first: offered ahead of the generated ones. */
  usedNames?: readonly string[];
}) {
  const [state, action, pending] = useActionState(
    kind === "budget" ? createBudgetAction : createRevenueTargetAction,
    idlePlanningActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const today = todayInBusinessZone();
  const submitLabel = kind === "budget" ? "Simpan Anggaran" : "Simpan Target Pendapatan";
  // The suggested titles follow the period type once it is chosen, so picking "Bulanan" first offers a
  // monthly name rather than an annual one (OWNER, 10 October 2026).
  const [periodType, setPeriodType] = useState<PlanPeriodType | "">("");
  const names = planNameSuggestions(kind, Number(today.slice(0, 4)), usedNames, periodType);

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity_id" value={entityId} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}

      <SuggestTextInput
        label="Nama"
        name="name"
        suggestions={names}
        noun={kind === "budget" ? "nama anggaran" : "nama target"}
        required
        maxLength={200}
        placeholder="Pilih dari daftar atau ketik sendiri"
      />

      <label>
        Jenis Periode
        <select
          name="period_type"
          required
          value={periodType}
          onChange={(event) => setPeriodType(event.target.value as PlanPeriodType | "")}
        >
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
