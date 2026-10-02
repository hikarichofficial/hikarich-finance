"use client";

import { useState } from "react";
import { PayrollToggleForm } from "./PayrollToggleForm";
import {
  addPayrollAdjustmentAction,
  createPayrollRunAction,
  payrollRunCommandAction,
  recordPayrollPaymentAction,
  removePayrollAdjustmentAction,
  reversePayrollPaymentAction,
} from "./payrollActions";

export interface PayrollOption {
  id: string;
  label: string;
}

export type PayrollRunCommand =
  | "calculate"
  | "submit"
  | "approve"
  | "return"
  | "discard"
  | "post"
  | "close"
  | "reopen"
  | "correct";

interface CommandCopy {
  openLabel: string;
  submitLabel: string;
  hint: string;
  needsReason: boolean;
  needsDate: boolean;
}

const COMMAND_COPY: Readonly<Record<PayrollRunCommand, CommandCopy>> = {
  calculate: {
    openLabel: "Hitung Payroll",
    submitLabel: "Hitung Sekarang",
    hint: "Menghitung gaji, BPJS dan PPh 21 semua karyawan bulan ini dari data terbaru.",
    needsReason: false,
    needsDate: false,
  },
  submit: {
    openLabel: "Ajukan untuk Disetujui",
    submitLabel: "Ajukan",
    hint: "Setelah diajukan, angka tidak bisa diubah kecuali dikembalikan ke draf.",
    needsReason: false,
    needsDate: false,
  },
  approve: {
    openLabel: "Setujui",
    submitLabel: "Setujui Payroll",
    hint: "Menyetujui hasil hitungan Payroll ini.",
    needsReason: false,
    needsDate: false,
  },
  return: {
    openLabel: "Kembalikan ke Draf",
    submitLabel: "Kembalikan",
    hint: "Payroll kembali menjadi draf supaya bisa diperbaiki dan dihitung ulang.",
    needsReason: true,
    needsDate: false,
  },
  discard: {
    openLabel: "Batalkan Proses",
    submitLabel: "Batalkan Proses Payroll",
    hint: "Proses ini dibuang dan tidak bisa dipakai lagi. Bulan ini bisa dibuat ulang.",
    needsReason: true,
    needsDate: false,
  },
  post: {
    openLabel: "Posting ke Pembukuan",
    submitLabel: "Posting Payroll",
    hint: "Membuat jurnal gaji, utang gaji, BPJS dan PPh 21. Setelah diposting hanya bisa dikoreksi.",
    needsReason: false,
    needsDate: false,
  },
  close: {
    openLabel: "Tutup Payroll",
    submitLabel: "Tutup",
    hint: "Menutup Payroll yang gaji bersihnya sudah dibayar penuh.",
    needsReason: false,
    needsDate: false,
  },
  reopen: {
    openLabel: "Buka Kembali",
    submitLabel: "Buka Kembali Payroll",
    hint: "Payroll yang sudah ditutup dibuka lagi. Perlu verifikasi ulang (step-up).",
    needsReason: true,
    needsDate: false,
  },
  correct: {
    openLabel: "Koreksi Payroll",
    submitLabel: "Koreksi",
    hint: "Jurnal dibalik, slip gaji dibatalkan dan revisi baru dibuat sebagai draf. Batalkan dulu semua pembayarannya. Perlu verifikasi ulang (step-up).",
    needsReason: true,
    needsDate: true,
  },
};

/** One status command of a payroll run as a small confirm form, with a reason and date where the RPC asks. */
export function RunCommandForm({
  runId,
  command,
  today,
}: {
  runId: string;
  command: PayrollRunCommand;
  today: string;
}) {
  const copy = COMMAND_COPY[command];

  return (
    <PayrollToggleForm
      action={payrollRunCommandAction}
      openLabel={copy.openLabel}
      submitLabel={copy.submitLabel}
    >
      <input type="hidden" name="run_id" value={runId} />
      <input type="hidden" name="command" value={command} />
      <p className="hint">{copy.hint}</p>
      {copy.needsDate ? (
        <label>
          Tanggal Jurnal Pembalik
          <input type="date" name="date" required defaultValue={today} max={today} />
        </label>
      ) : null}
      {copy.needsReason ? (
        <label>
          Alasan
          <input name="reason" required minLength={5} maxLength={500} />
        </label>
      ) : null}
    </PayrollToggleForm>
  );
}

/** A one-off earning or deduction for one employee in this run (`payroll_adjustment_add`). */
export function AdjustmentForm({
  runId,
  employees,
}: {
  runId: string;
  employees: readonly PayrollOption[];
}) {
  return (
    <PayrollToggleForm
      action={addPayrollAdjustmentAction}
      openLabel="Tambah Penyesuaian"
      submitLabel="Simpan Penyesuaian"
    >
      <input type="hidden" name="run_id" value={runId} />
      <label>
        Karyawan
        <select name="employee_id" required defaultValue="">
          <option value="" disabled>
            Pilih karyawan
          </option>
          {employees.map((employee) => (
            <option key={employee.id} value={employee.id}>
              {employee.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Jenis
        <select name="kind" defaultValue="earning">
          <option value="earning">Penghasilan (mis. bonus, lembur)</option>
          <option value="deduction">Potongan (mis. kasbon)</option>
        </select>
      </label>
      <label>
        Nama Penyesuaian
        <input name="label" required maxLength={120} />
      </label>
      <label>
        Jumlah
        <input name="amount" required inputMode="decimal" placeholder="0" />
      </label>
      <label className="checkbox-field">
        <input type="checkbox" name="taxable" defaultChecked /> Dihitung untuk PPh 21
      </label>
    </PayrollToggleForm>
  );
}

/** Remove one adjustment while the run is a draft or calculated (`payroll_adjustment_remove`). */
export function RemoveAdjustmentForm({
  runId,
  adjustments,
}: {
  runId: string;
  adjustments: readonly PayrollOption[];
}) {
  return (
    <PayrollToggleForm
      action={removePayrollAdjustmentAction}
      openLabel="Hapus Penyesuaian"
      submitLabel="Hapus"
    >
      <input type="hidden" name="run_id" value={runId} />
      <label>
        Penyesuaian
        <select name="adjustment_id" required defaultValue="">
          <option value="" disabled>
            Pilih penyesuaian
          </option>
          {adjustments.map((adjustment) => (
            <option key={adjustment.id} value={adjustment.id}>
              {adjustment.label}
            </option>
          ))}
        </select>
      </label>
    </PayrollToggleForm>
  );
}

/**
 * Pay the run (`payroll_record_payment`, `payroll.pay`, needs a fresh step-up): all net pay still owed in
 * one payment, or one BPJS amount. Paying net pay for selected employees only is not offered here.
 */
export function PayrollPaymentForm({
  runId,
  accounts,
  today,
}: {
  runId: string;
  accounts: readonly PayrollOption[];
  today: string;
}) {
  const [kind, setKind] = useState("net_pay");

  return (
    <PayrollToggleForm
      action={recordPayrollPaymentAction}
      openLabel="Catat Pembayaran"
      submitLabel="Simpan Pembayaran"
    >
      <input type="hidden" name="run_id" value={runId} />
      <label>
        Yang Dibayar
        <select name="kind" value={kind} onChange={(event) => setKind(event.target.value)}>
          <option value="net_pay">Gaji bersih (semua yang belum dibayar)</option>
          <option value="bpjs">Iuran BPJS</option>
        </select>
      </label>
      {kind === "bpjs" ? (
        <label>
          Jumlah BPJS yang Dibayar
          <input name="amount" required inputMode="decimal" placeholder="0" />
        </label>
      ) : null}
      <label>
        Dibayar dari Rekening
        <select name="account_id" required defaultValue="">
          <option value="" disabled>
            Pilih rekening kas/bank
          </option>
          {accounts.map((account) => (
            <option key={account.id} value={account.id}>
              {account.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal Bayar
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Nomor Referensi Transfer (opsional)
        <input name="reference" maxLength={200} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} />
      </label>
      <p className="hint">Perlu verifikasi ulang (step-up) sebelum menyimpan pembayaran.</p>
    </PayrollToggleForm>
  );
}

/** Reverse one confirmed payment of the run (`payroll_reverse_payment`, `payroll.pay`, step-up). */
export function ReversePayrollPaymentForm({
  runId,
  payments,
  today,
}: {
  runId: string;
  payments: readonly PayrollOption[];
  today: string;
}) {
  return (
    <PayrollToggleForm
      action={reversePayrollPaymentAction}
      openLabel="Batalkan Pembayaran"
      submitLabel="Batalkan Pembayaran"
    >
      <input type="hidden" name="run_id" value={runId} />
      <label>
        Pembayaran
        <select name="payment_id" required defaultValue="">
          <option value="" disabled>
            Pilih pembayaran
          </option>
          {payments.map((payment) => (
            <option key={payment.id} value={payment.id}>
              {payment.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Tanggal Pembatalan
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Alasan
        <input name="reason" required minLength={5} maxLength={500} />
      </label>
      <p className="hint">Perlu verifikasi ulang (step-up) sebelum membatalkan pembayaran.</p>
    </PayrollToggleForm>
  );
}

/** Start the payroll run of one month (`payroll_run_create`, `payroll.run`). */
export function CreatePayrollRunForm({
  entity,
  today,
}: {
  entity: string | undefined;
  today: string;
}) {
  return (
    <PayrollToggleForm
      action={createPayrollRunAction}
      openLabel="Buat Proses Payroll"
      submitLabel="Buat"
      primary
    >
      <input type="hidden" name="entity" value={entity ?? ""} />
      <label>
        Bulan Gaji (pilih tanggal mana saja di bulan itu)
        <input type="date" name="period" required defaultValue={today} />
      </label>
      <label>
        Tanggal Bayar
        <input type="date" name="pay_date" required defaultValue={today} />
      </label>
      <label>
        Catatan (opsional)
        <input name="note" maxLength={1000} />
      </label>
    </PayrollToggleForm>
  );
}
