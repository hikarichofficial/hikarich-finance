"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import type { AssetActionState } from "./assetActions";

/** The class for a form label that is wrong: red border and wash (see `.field-invalid` in globals.css). */
export function invalidClass(message: string | undefined): string | undefined {
  return message ? "field-invalid" : undefined;
}

/** The words under a field that is wrong. */
export function FieldProblem({ message }: { message: string | undefined }) {
  return message ? (
    <span role="alert" className="field-error">
      {message}
    </span>
  ) : null;
}

/**
 * The box at the bottom of a form the database refused: what went wrong, the way out, and which field is red.
 * The field itself is marked by the form (`state.field`); this only writes the explanation.
 */
export function FormProblem({ state, next }: { state: AssetActionState; next: string }) {
  if (state.status !== "error") return null;
  return (
    <div role="alert" className="form-problem">
      <p className="form-problem-title">Aset belum bisa disimpan</p>
      <p>{state.message}</p>
      {state.fix ? <p>Cara memperbaiki: {state.fix}</p> : null}
      {state.stepUp ? (
        <p>
          <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(next)}`}>
            Verifikasi ulang →
          </StepUpLink>
        </p>
      ) : null}
    </div>
  );
}

/** Baru / Bekas and the year of manufacture, for the opening and activation forms (decision 343). */
export function AssetOriginFields({
  condition,
  year,
  onConditionChange,
  onYearChange,
  yearProblem,
}: {
  condition: "new" | "used";
  year: string;
  onConditionChange: (condition: "new" | "used") => void;
  onYearChange: (year: string) => void;
  yearProblem?: string;
}) {
  return (
    <>
      <label>
        Kondisi Saat Dibeli
        <select
          name="acquired_condition"
          value={condition}
          onChange={(event) => onConditionChange(event.target.value === "used" ? "used" : "new")}
        >
          <option value="new">Baru (belum pernah dipakai orang lain)</option>
          <option value="used">Bekas (mobil bekas, laptop bekas, dll.)</option>
        </select>
      </label>
      <label className={invalidClass(yearProblem)}>
        Tahun Pembuatan{condition === "used" ? "" : " (opsional)"}
        <input
          name="manufacture_year"
          inputMode="numeric"
          maxLength={4}
          required={condition === "used"}
          placeholder="mis. 2019, tahun barang keluar dari pabrik atau dealer"
          value={year}
          onChange={(event) => onYearChange(event.target.value.replace(/\D/g, ""))}
        />
        <FieldProblem message={yearProblem} />
      </label>
    </>
  );
}
