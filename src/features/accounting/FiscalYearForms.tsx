"use client";

import { StepUpLink } from "@/features/feedback/StepUp";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState } from "@/features/feedback/useActionState";
import {
  closeFiscalYearAction,
  reverseFiscalYearClosingAction,
  type FiscalYearState,
} from "./fiscalYearActions";

const IDLE: FiscalYearState = { status: "idle" };

function Feedback({ state, next }: { state: FiscalYearState; next: string }) {
  if (state.status === "ok") return <p className="hint">{state.message}</p>;
  if (state.status !== "error") return null;
  return (
    <p role="alert" className="error">
      {state.message}{" "}
      {state.stepUp ? (
        <StepUpLink href={`/auth/step-up?next=${encodeURIComponent(next)}`}>
          Verifikasi ulang →
        </StepUpLink>
      ) : null}
    </p>
  );
}

function CloseYearForm({
  entity,
  years,
  next,
}: {
  entity: string | undefined;
  years: readonly number[];
  next: string;
}) {
  const [state, action, pending] = useActionState(closeFiscalYearAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <p className="hint">
        Menutup tahun buku memindahkan laba/rugi tahun itu ke saldo laba dengan satu jurnal penutup.
        Semua periode di tahun itu harus sudah ditutup lebih dulu.
      </p>
      <label>
        Tahun Buku
        <select name="fiscal_year" required defaultValue={String(years[0] ?? "")}>
          {years.map((year) => (
            <option key={year} value={year}>
              {year}
            </option>
          ))}
        </select>
      </label>
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menutup…" : "Tutup Tahun Buku"}
      </button>
    </form>
  );
}

function ReverseYearForm({
  entity,
  years,
  next,
}: {
  entity: string | undefined;
  years: readonly number[];
  next: string;
}) {
  const [state, action, pending] = useActionState(reverseFiscalYearClosingAction, IDLE);
  const actionForm = usePreservingForm(action, state);
  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <p className="hint">
        Membatalkan penutupan membuat jurnal pembalik untuk jurnal penutup tahun itu. Perlu
        verifikasi ulang.
      </p>
      <label>
        Tahun Buku yang Sudah Ditutup
        <select name="fiscal_year" required defaultValue={String(years[0] ?? "")}>
          {years.map((year) => (
            <option key={year} value={year}>
              {year}
            </option>
          ))}
        </select>
      </label>
      <label>
        Alasan (minimal 10 karakter)
        <textarea name="reason" required minLength={10} maxLength={500} />
      </label>
      <Feedback state={state} next={next} />
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Membatalkan…" : "Batalkan Penutupan Tahun"}
      </button>
    </form>
  );
}

/**
 * Year-end closing (Step 12) on Accounting Periods: close a fiscal year (`close_fiscal_year`,
 * `periods.close`) or reverse an active closing (`reverse_fiscal_year_closing`, `periods.reopen` and a
 * recent step-up). A year that is already closed is offered only for reversal, and the other way round.
 */
export function FiscalYearForms({
  entity,
  years,
  closedYears,
  canClose,
  canReverse,
  next,
}: {
  entity: string | undefined;
  years: readonly number[];
  closedYears: readonly number[];
  canClose: boolean;
  canReverse: boolean;
  next: string;
}) {
  const openYears = years.filter((year) => !closedYears.includes(year));
  const showClose = canClose && openYears.length > 0;
  const showReverse = canReverse && closedYears.length > 0;

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Penutupan Tahun Buku</h2>
      </div>
      {closedYears.length > 0 ? (
        <p className="hint">Tahun yang sudah ditutup: {closedYears.join(", ")}.</p>
      ) : null}
      {showClose ? <CloseYearForm entity={entity} years={openYears} next={next} /> : null}
      {showReverse ? <ReverseYearForm entity={entity} years={closedYears} next={next} /> : null}
      {!showClose && !showReverse ? (
        <p className="hint">Tidak ada tindakan penutupan tahun yang tersedia saat ini.</p>
      ) : null}
    </section>
  );
}
