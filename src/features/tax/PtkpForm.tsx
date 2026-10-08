"use client";

import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { ptkpLabel } from "@/domain/tax/personalTax";
import { PTKP_STATUSES, type PtkpStatus } from "@/schemas/personalTax";
import { setPtkpAction } from "./personalTaxActions";
import { idlePtkpState } from "./personalTaxActionsState";

/** Status PTKP for the year: one select and one button; the estimate recalculates on save. */
export function PtkpForm({
  entity,
  year,
  current,
  amounts,
}: {
  entity: string | undefined;
  year: number;
  current: PtkpStatus | null;
  /** PTKP amount per status, already formatted, so the choices show what each one is worth. */
  amounts: Record<string, string>;
}) {
  const [state, action, pending] = useActionState(setPtkpAction, idlePtkpState);
  const form = usePreservingForm(action, state);

  return (
    <form {...form} className="pp-ptkp-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="year" value={year} />
      <label>
        Status PTKP {year}
        <select name="status" defaultValue={current ?? "TK/0"}>
          {PTKP_STATUSES.map((status) => (
            <option key={status} value={status}>
              {status} · {ptkpLabel(status)} · {amounts[status] ?? ""}
            </option>
          ))}
        </select>
      </label>
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan"}
      </button>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      {state.status === "ok" ? <p className="hint">{state.message}</p> : null}
    </form>
  );
}
