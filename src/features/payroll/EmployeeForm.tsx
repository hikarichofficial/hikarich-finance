"use client";

import { useActionState } from "react";
import { createEmployeeAction, type PayrollActionState } from "./payrollActions";

const IDLE: PayrollActionState = { status: "idle" };

/** Add Employee through `employee_create` (`payroll.employee_edit`). */
export function EmployeeForm({ entity, today }: { entity: string | undefined; today: string }) {
  const [state, action, pending] = useActionState(createEmployeeAction, IDLE);

  return (
    <form action={action} className="record-form">
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Nama Lengkap
        <input name="full_name" required minLength={2} maxLength={200} />
      </label>
      <label>
        Tanggal Masuk
        <input type="date" name="join_date" required defaultValue={today} />
      </label>
      <label>
        Jenis Karyawan
        <select name="employment_type" defaultValue="permanent">
          <option value="permanent">Karyawan tetap</option>
          <option value="contract">Kontrak</option>
          <option value="probation">Percobaan</option>
          <option value="part_time">Paruh waktu</option>
        </select>
      </label>
      <label>
        Jabatan
        <input name="position_title" required maxLength={120} />
      </label>
      <label>
        Departemen (opsional)
        <input name="department" maxLength={120} />
      </label>
      <p className="hint">
        Setelah disimpan, isi gaji, data pajak dan BPJS di halaman karyawan tersebut.
      </p>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-primary" disabled={pending}>
        {pending ? "Menyimpan…" : "Simpan"}
      </button>
    </form>
  );
}
