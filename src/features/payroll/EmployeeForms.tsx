"use client";

import { useState } from "react";
import { PayrollToggleForm } from "./PayrollToggleForm";
import {
  endEmployeeAction,
  recordEmploymentAction,
  setBpjsAction,
  setTaxOpeningAction,
  setTaxProfileAction,
  updateEmployeeAction,
} from "./payrollActions";
import { MoneyInput } from "@/features/shared/MoneyInput";

export { CompensationForm, type CompensationRowView } from "./CompensationForm";

/** Change the name, and the join date while no posted Payroll has counted the employee (`employee_update`). */
export function UpdateEmployeeForm({
  employeeId,
  fullName,
  joinDate,
}: {
  employeeId: string;
  fullName: string;
  joinDate: string;
}) {
  return (
    <PayrollToggleForm
      action={updateEmployeeAction}
      openLabel="Ubah Data"
      submitLabel="Simpan Perubahan"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Nama Lengkap
        <input name="full_name" required minLength={2} maxLength={200} defaultValue={fullName} />
      </label>
      <label>
        Tanggal Masuk
        <input type="date" name="join_date" defaultValue={joinDate} />
      </label>
      <p className="hint">
        Tanggal masuk tidak bisa diubah bila karyawan sudah masuk Payroll yang diposting.
      </p>
    </PayrollToggleForm>
  );
}

/** A new position, department or employment type from a date (`employee_record_employment`). */
export function EmploymentForm({
  employeeId,
  employmentType,
  positionTitle,
  department,
  today,
}: {
  employeeId: string;
  employmentType: string;
  positionTitle: string;
  department: string | null;
  today: string;
}) {
  return (
    <PayrollToggleForm
      action={recordEmploymentAction}
      openLabel="Catat Perubahan Jabatan"
      submitLabel="Simpan Jabatan"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <label>
        Jenis Karyawan
        <select name="employment_type" defaultValue={employmentType}>
          <option value="permanent">Karyawan tetap</option>
          <option value="contract">Kontrak</option>
          <option value="probation">Percobaan</option>
          <option value="part_time">Paruh waktu</option>
        </select>
      </label>
      <label>
        Jabatan
        <input name="position_title" required maxLength={120} defaultValue={positionTitle} />
      </label>
      <label>
        Departemen (opsional)
        <input name="department" maxLength={120} defaultValue={department ?? ""} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={500} />
      </label>
    </PayrollToggleForm>
  );
}

export interface TaxProfileView {
  taxIdStatus: string;
  ptkpStatus: string;
  taxMethod: string;
}

const PTKP_OPTIONS = ["TK/0", "TK/1", "TK/2", "TK/3", "K/0", "K/1", "K/2", "K/3"] as const;

/** PTKP status, NPWP/NIK status and tax method from a date (`employee_set_tax_profile`). */
export function TaxProfileForm({
  employeeId,
  current,
  today,
}: {
  employeeId: string;
  current: TaxProfileView | null;
  today: string;
}) {
  return (
    <PayrollToggleForm
      action={setTaxProfileAction}
      openLabel="Atur Data Pajak"
      submitLabel="Simpan Data Pajak"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <label>
        Status NPWP/NIK
        <select name="tax_id_status" defaultValue={current?.taxIdStatus ?? "unknown"}>
          <option value="has_tax_id">Punya NPWP/NIK</option>
          <option value="no_tax_id">Tidak punya NPWP/NIK</option>
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Nomor NPWP/NIK (15 atau 16 angka; isi hanya bila punya)
        <input name="tax_id" maxLength={40} inputMode="numeric" autoComplete="off" />
      </label>
      <label>
        Status PTKP
        <select name="ptkp_status" defaultValue={current?.ptkpStatus ?? "unknown"}>
          {PTKP_OPTIONS.map((status) => (
            <option key={status} value={status}>
              {status}
            </option>
          ))}
          <option value="unknown">Belum diketahui</option>
        </select>
      </label>
      <label>
        Metode Pajak
        <select name="tax_method" defaultValue={current?.taxMethod ?? "employee_borne"}>
          <option value="employee_borne">Ditanggung karyawan</option>
          <option value="gross_up">Ditanggung perusahaan (gross-up)</option>
        </select>
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={500} />
      </label>
      <p className="hint">
        Nomor yang sudah tersimpan tidak ditampilkan di sini; isi lagi bila statusnya punya
        NPWP/NIK.
      </p>
    </PayrollToggleForm>
  );
}

const BPJS_KES = "bpjs_kes";
const BPJS_TK = ["bpjs_jht", "bpjs_jp", "bpjs_jkk", "bpjs_jkm"] as const;
const BPJS_ALL = [BPJS_KES, ...BPJS_TK] as const;

const JKK_GRADES = ["grade_1", "grade_2", "grade_3", "grade_4", "grade_5"] as const;

type BpjsPackage = "full" | "kes" | "tk" | "none";

const BPJS_PACKAGES: readonly { key: BpjsPackage; title: string; text: string }[] = [
  {
    key: "full",
    title: "Lengkap",
    text: "BPJS Kesehatan + BPJS Ketenagakerjaan (JHT, JP, JKK, JKM). Pilihan umum untuk karyawan tetap.",
  },
  { key: "kes", title: "Hanya Kesehatan", text: "BPJS Kesehatan saja." },
  { key: "tk", title: "Hanya Ketenagakerjaan", text: "JHT, JP, JKK dan JKM tanpa BPJS Kesehatan." },
  { key: "none", title: "Tidak ikut BPJS", text: "Tidak ada iuran BPJS di payroll karyawan ini." },
];

export interface BpjsRowView {
  component: string;
  rateKey: string | null;
  memberRef: string | null;
}

function packageOf(current: readonly BpjsRowView[]): BpjsPackage {
  if (current.length === 0) return "full";
  const has = (code: string) => current.some((row) => row.component === code);
  const kes = has(BPJS_KES);
  const tk = BPJS_TK.some(has);
  if (kes && tk) return "full";
  if (kes) return "kes";
  if (tk) return "tk";
  return "none";
}

function includes(choice: BpjsPackage, code: string): boolean {
  if (choice === "full") return true;
  if (choice === "kes") return code === BPJS_KES;
  if (choice === "tk") return code !== BPJS_KES;
  return false;
}

/**
 * BPJS enrolment from a date (`employee_set_bpjs`, `payroll.compensation_edit`). OWNER, 9 October 2026: five
 * programs with a "no change / yes / no" choice each was too much, so one package is picked instead ("Lengkap"
 * for a person with nothing recorded yet) and the five programs are posted from it: "yes" for each program in the
 * package, "no" for a program the person is enrolled in now but the package leaves out. The posted fields are the
 * same as before (`enrolled_*`, `rate_key_bpjs_jkk`, `member_ref_*`).
 */
export function BpjsForm({
  employeeId,
  current,
  today,
}: {
  employeeId: string;
  current: readonly BpjsRowView[];
  today: string;
}) {
  const [choice, setChoice] = useState<BpjsPackage>(() => packageOf(current));
  const existing = (code: string) => current.find((row) => row.component === code);
  const enrolledNow = (code: string) => existing(code) !== undefined;
  const memberRef = (codes: readonly string[]) =>
    codes.map((code) => existing(code)?.memberRef).find((value) => value) ?? "";

  return (
    <PayrollToggleForm
      action={setBpjsAction}
      openLabel="Atur BPJS"
      submitLabel="Simpan BPJS"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Berlaku mulai
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <p className="hint">
        Pilih paket kepesertaan saja; iuran dihitung otomatis dari gaji tiap bulan. BPJS Kesehatan
        dan BPJS Ketenagakerjaan dibayar terpisah.
      </p>

      <div className="choice-cards" role="radiogroup" aria-label="Paket BPJS">
        {BPJS_PACKAGES.map((option) => (
          <button
            key={option.key}
            type="button"
            role="radio"
            aria-checked={choice === option.key}
            className="choice-card"
            onClick={() => setChoice(option.key)}
          >
            <strong>{option.title}</strong>
            <span>{option.text}</span>
          </button>
        ))}
      </div>

      {BPJS_ALL.map((code) => {
        const inPackage = includes(choice, code);
        const value = inPackage ? "yes" : enrolledNow(code) ? "no" : "";
        return <input key={code} type="hidden" name={`enrolled_${code}`} value={value} />;
      })}

      {includes(choice, "bpjs_jkk") ? (
        <label>
          Tingkat risiko JKK
          <select
            name="rate_key_bpjs_jkk"
            defaultValue={existing("bpjs_jkk")?.rateKey ?? "grade_1"}
          >
            {JKK_GRADES.map((grade, index) => (
              <option key={grade} value={grade}>
                Tingkat {index + 1}
                {index === 0 ? " (kantor, jasa, digital)" : ""}
              </option>
            ))}
          </select>
        </label>
      ) : null}

      {choice !== "none" ? (
        <details className="comp-optional">
          <summary>Nomor kartu BPJS (opsional)</summary>
          {includes(choice, BPJS_KES) ? (
            <label>
              Nomor BPJS Kesehatan
              <input
                name={`member_ref_${BPJS_KES}`}
                maxLength={60}
                defaultValue={memberRef([BPJS_KES])}
              />
            </label>
          ) : null}
          {choice !== "kes" ? (
            <label>
              Nomor BPJS Ketenagakerjaan
              <input name="member_ref_bpjs_jht" maxLength={60} defaultValue={memberRef(BPJS_TK)} />
            </label>
          ) : null}
        </details>
      ) : null}
    </PayrollToggleForm>
  );
}

/**
 * Income and PPh 21 already withheld this tax year before the books start (`employee_set_tax_opening`,
 * Step 17). Only for an employee who was already paid earlier this tax year outside this app; a new employee
 * needs nothing here (the screen does not offer it then).
 */
export function TaxOpeningForm({
  employeeId,
  year,
  defaultMonth,
}: {
  employeeId: string;
  year: number;
  /** The month before the current one: the last month already paid elsewhere when the app is started now. */
  defaultMonth: number;
}) {
  return (
    <PayrollToggleForm
      action={setTaxOpeningAction}
      openLabel="Isi Saldo Awal Pajak (karyawan lama)"
      submitLabel="Simpan Saldo Awal Pajak"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <p className="hint">
        <strong>
          Hanya bila karyawan ini sudah digaji sebelum Anda memakai aplikasi, pada tahun pajak yang
          sama.
        </strong>{" "}
        Supaya PPh 21 sisa tahun dihitung benar, aplikasi perlu tahu berapa penghasilan dan PPh 21
        yang sudah terpotong sampai bulan terakhir sebelum pakai aplikasi. Contoh: mulai memakai
        aplikasi di Oktober, isi &quot;Sampai Bulan&quot; 9, lalu total gaji kena pajak dan total
        PPh 21 dari slip Januari–September. Karyawan baru atau yang baru pertama digaji lewat
        aplikasi: lewati saja, tidak perlu diisi.
      </p>
      <label>
        Tahun Pajak
        <input type="number" name="tax_year" required min={2000} max={2100} defaultValue={year} />
      </label>
      <label>
        Sampai Bulan ke- (1 sampai 11)
        <input
          type="number"
          name="through_month"
          required
          min={1}
          max={11}
          defaultValue={defaultMonth}
        />
      </label>
      <label>
        Total Penghasilan Bruto Kena Pajak (Januari sampai bulan itu)
        <MoneyInput name="taxable_gross" required placeholder="0" />
      </label>
      <label>
        Total Iuran Pensiun/JHT yang Dipotong
        <MoneyInput name="pension_deduction" defaultValue="0" />
      </label>
      <label>
        Total PPh 21 yang Sudah Dipotong
        <MoneyInput name="pph21_withheld" required placeholder="0" />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={500} />
      </label>
    </PayrollToggleForm>
  );
}

/** Mark the employee as having left (`employee_end`). */
export function EndEmployeeForm({ employeeId, today }: { employeeId: string; today: string }) {
  return (
    <PayrollToggleForm
      action={endEmployeeAction}
      openLabel="Karyawan Berhenti"
      submitLabel="Simpan Tanggal Berhenti"
      alwaysOpen
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Tanggal Berhenti
        <input type="date" name="exit_date" required defaultValue={today} />
      </label>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <p className="hint">Karyawan yang sudah berhenti tidak masuk Payroll bulan berikutnya.</p>
    </PayrollToggleForm>
  );
}
