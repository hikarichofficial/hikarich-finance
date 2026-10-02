"use client";

import { useState } from "react";
import { PayrollToggleForm } from "./PayrollToggleForm";
import {
  endEmployeeAction,
  recordEmploymentAction,
  setBpjsAction,
  setCompensationAction,
  setTaxOpeningAction,
  setTaxProfileAction,
  updateEmployeeAction,
} from "./payrollActions";

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

export interface CompensationRowView {
  component: string;
  kind: string;
  label: string;
  amount: string;
  taxable: boolean;
  bpjsBase: boolean;
}

const EMPTY_ROW: CompensationRowView = {
  component: "",
  kind: "earning",
  label: "",
  amount: "",
  taxable: true,
  bpjsBase: false,
};

const FIRST_ROW: CompensationRowView = {
  component: "gaji_pokok",
  kind: "earning",
  label: "Gaji Pokok",
  amount: "",
  taxable: true,
  bpjsBase: true,
};

/**
 * Salary components from a date (`employee_set_compensation`, `payroll.compensation_edit`). Each component
 * is effective-dated on its own: a row saved here replaces that component from the date given, and a
 * component left out keeps its current amount. A row with no name and no amount is ignored.
 */
export function CompensationForm({
  employeeId,
  current,
  today,
}: {
  employeeId: string;
  current: readonly CompensationRowView[];
  today: string;
}) {
  const [rows, setRows] = useState<readonly CompensationRowView[]>(
    current.length > 0 ? current : [FIRST_ROW],
  );

  return (
    <PayrollToggleForm
      action={setCompensationAction}
      openLabel="Atur Gaji & Komponen"
      submitLabel="Simpan Kompensasi"
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <input type="hidden" name="row_count" value={rows.length} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <p className="hint">
        Isi komponen yang baru atau berubah saja; komponen lain tetap seperti sebelumnya. Kosongkan
        nama dan jumlah pada baris yang tidak dipakai.
      </p>
      {rows.map((row, index) => (
        <fieldset key={index}>
          <legend>Komponen {index + 1}</legend>
          <label>
            Nama
            <input
              name={`label_${index}`}
              maxLength={120}
              defaultValue={row.label}
              placeholder="mis. Tunjangan Transport"
            />
          </label>
          <label>
            Kode (huruf kecil, tanpa spasi)
            <input
              name={`component_${index}`}
              maxLength={41}
              defaultValue={row.component}
              placeholder="mis. tunjangan_transport"
            />
          </label>
          <label>
            Jenis
            <select name={`kind_${index}`} defaultValue={row.kind}>
              <option value="earning">Penghasilan</option>
              <option value="deduction">Potongan</option>
            </select>
          </label>
          <label>
            Jumlah per Bulan
            <input
              name={`amount_${index}`}
              inputMode="decimal"
              defaultValue={row.amount}
              placeholder="0"
            />
          </label>
          <label className="checkbox-field">
            <input type="checkbox" name={`taxable_${index}`} defaultChecked={row.taxable} />{" "}
            Dihitung untuk PPh 21
          </label>
          <label className="checkbox-field">
            <input type="checkbox" name={`bpjs_base_${index}`} defaultChecked={row.bpjsBase} />{" "}
            Masuk dasar upah BPJS (hanya penghasilan)
          </label>
        </fieldset>
      ))}
      {rows.length < 30 ? (
        <button
          type="button"
          className="btn-secondary"
          onClick={() => setRows((previous) => [...previous, EMPTY_ROW])}
        >
          Tambah Komponen
        </button>
      ) : null}
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

const BPJS_PROGRAMS = [
  { code: "bpjs_kes", label: "BPJS Kesehatan" },
  { code: "bpjs_jht", label: "BPJS JHT" },
  { code: "bpjs_jp", label: "BPJS JP" },
  { code: "bpjs_jkk", label: "BPJS JKK" },
  { code: "bpjs_jkm", label: "BPJS JKM" },
] as const;

const JKK_GRADES = ["grade_1", "grade_2", "grade_3", "grade_4", "grade_5"] as const;

export interface BpjsRowView {
  component: string;
  rateKey: string | null;
  memberRef: string | null;
}

/**
 * BPJS enrolment from a date (`employee_set_bpjs`, `payroll.compensation_edit`). Each program is
 * effective-dated on its own, so only the programs set to "Terdaftar" or "Tidak terdaftar" are sent.
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
  return (
    <PayrollToggleForm action={setBpjsAction} openLabel="Atur BPJS" submitLabel="Simpan BPJS">
      <input type="hidden" name="employee_id" value={employeeId} />
      <label>
        Berlaku Sejak
        <input type="date" name="effective_from" required defaultValue={today} />
      </label>
      <p className="hint">Pilih hanya program yang berubah; sisanya biarkan Tidak diubah.</p>
      {BPJS_PROGRAMS.map((program) => {
        const existing = current.find((row) => row.component === program.code);
        return (
          <fieldset key={program.code}>
            <legend>
              {program.label}
              {existing ? " (sekarang terdaftar)" : ""}
            </legend>
            <label>
              Kepesertaan
              <select name={`enrolled_${program.code}`} defaultValue="">
                <option value="">Tidak diubah</option>
                <option value="yes">Terdaftar</option>
                <option value="no">Tidak terdaftar</option>
              </select>
            </label>
            {program.code === "bpjs_jkk" ? (
              <label>
                Tingkat Risiko JKK
                <select name={`rate_key_${program.code}`} defaultValue={existing?.rateKey ?? ""}>
                  <option value="">Pilih tingkat risiko</option>
                  {JKK_GRADES.map((grade, index) => (
                    <option key={grade} value={grade}>
                      Tingkat {index + 1}
                    </option>
                  ))}
                </select>
              </label>
            ) : null}
            <label>
              Nomor Anggota (opsional)
              <input
                name={`member_ref_${program.code}`}
                maxLength={60}
                defaultValue={existing?.memberRef ?? ""}
              />
            </label>
          </fieldset>
        );
      })}
    </PayrollToggleForm>
  );
}

/**
 * Income and PPh 21 already withheld this tax year before the books start (`employee_set_tax_opening`,
 * Step 17), for an employee whose first Payroll here is not January.
 */
export function TaxOpeningForm({ employeeId, year }: { employeeId: string; year: number }) {
  return (
    <PayrollToggleForm
      action={setTaxOpeningAction}
      openLabel="Isi Saldo Awal Pajak"
      submitLabel="Simpan Saldo Awal Pajak"
    >
      <input type="hidden" name="employee_id" value={employeeId} />
      <p className="hint">
        Untuk karyawan yang sudah digaji sebelum memakai aplikasi ini: isi total penghasilan dan PPh
        21 yang sudah dipotong pada tahun pajak itu.
      </p>
      <label>
        Tahun Pajak
        <input type="number" name="tax_year" required min={2000} max={2100} defaultValue={year} />
      </label>
      <label>
        Sampai Bulan (1-11)
        <input type="number" name="through_month" required min={1} max={11} />
      </label>
      <label>
        Total Penghasilan Bruto Kena Pajak
        <input name="taxable_gross" required inputMode="decimal" placeholder="0" />
      </label>
      <label>
        Total Iuran Pensiun/JHT yang Dipotong
        <input name="pension_deduction" inputMode="decimal" defaultValue="0" />
      </label>
      <label>
        Total PPh 21 yang Sudah Dipotong
        <input name="pph21_withheld" required inputMode="decimal" placeholder="0" />
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
