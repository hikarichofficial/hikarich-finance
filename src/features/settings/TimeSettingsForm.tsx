"use client";

import Link from "next/link";
import { useActionState } from "react";
import { monthName, timezoneOptions } from "@/domain/settings/settings";
import { updateTimeSettingsAction } from "./actions";
import { idleTimeSettingsState } from "./actionsState";

const MONTHS = Array.from({ length: 12 }, (_, i) => i + 1);

/** Edit the Entity's timezone and fiscal-year start (decision 248). Tax periods, due dates and "today"
 * follow these; the fiscal-year start is locked once accounting periods exist. */
export function TimeSettingsForm({
  entity,
  timezone,
  fiscalYearStartMonth,
  version,
  fiscalYearLocked,
  stepUpHref,
}: {
  entity: string | undefined;
  timezone: string;
  fiscalYearStartMonth: number;
  version: number;
  fiscalYearLocked: boolean;
  stepUpHref: string;
}) {
  const [state, action, pending] = useActionState(updateTimeSettingsAction, idleTimeSettingsState);
  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <input type="hidden" name="expected_version" value={version} />
      <p className="hint">
        Masa dan tahun pajak dihitung dengan zona waktu dan tahun buku Entity ini (bawaan: WIB,
        Januari–Desember, sesuai tahun takwim). Perubahan memerlukan verifikasi ulang dalam 10 menit
        terakhir. <Link href={stepUpHref}>Verifikasi sekarang</Link>.
      </p>
      <label>
        Zona waktu
        <select name="timezone" defaultValue={timezone}>
          {timezoneOptions(timezone).map((z) => (
            <option key={z.value} value={z.value}>
              {z.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Awal tahun buku
        {fiscalYearLocked ? (
          <input type="hidden" name="fiscal_year_start_month" value={fiscalYearStartMonth} />
        ) : null}
        <select
          name={fiscalYearLocked ? undefined : "fiscal_year_start_month"}
          defaultValue={fiscalYearStartMonth}
          disabled={fiscalYearLocked}
        >
          {MONTHS.map((m) => (
            <option key={m} value={m}>
              {monthName(m)}
            </option>
          ))}
        </select>
      </label>
      {fiscalYearLocked ? (
        <p className="hint">Awal tahun buku terkunci karena periode akuntansi sudah dibuat.</p>
      ) : null}
      <label>
        Alasan perubahan (minimal 5 karakter)
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <div>
        <button type="submit" className="btn-primary" disabled={pending}>
          {pending ? "Menyimpan…" : "Simpan"}
        </button>
      </div>
      {state.status !== "idle" ? (
        <p
          role={state.status === "error" ? "alert" : "status"}
          className={state.status === "error" ? "error" : "hint"}
        >
          {state.message}
          {state.stepUp ? (
            <>
              {" "}
              <Link href={stepUpHref}>Verifikasi sekarang</Link>.
            </>
          ) : null}
        </p>
      ) : null}
    </form>
  );
}
