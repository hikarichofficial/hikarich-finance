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
import { MoneyInput } from "@/features/shared/MoneyInput";
import { formatMoney } from "@/domain/money/format";

export interface PayrollOption {
  id: string;
  label: string;
}

/** An employee on the adjustment form, with the pro-rata figures when this month is a part month. */
export interface AdjustmentEmployee extends PayrollOption {
  prorata?: {
    daysWorked: number;
    daysInPeriod: number;
    proratedGross: string;
    deduction: string;
    label: string;
    /** "Mulai bekerja 15 Okt 2026" or "Berhenti 10 Okt 2026", for the line that explains the figure. */
    reason: string;
    grossPay: string;
  } | null;
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
    hint: "Payroll yang sudah ditutup dibuka lagi. Perlu verifikasi ulang.",
    needsReason: true,
    needsDate: false,
  },
  correct: {
    openLabel: "Koreksi Payroll",
    submitLabel: "Koreksi",
    hint: "Jurnal dibalik, slip gaji dibatalkan dan revisi baru dibuat sebagai draf. Batalkan dulu semua pembayarannya. Perlu verifikasi ulang.",
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
  currency,
}: {
  runId: string;
  employees: readonly AdjustmentEmployee[];
  currency: string;
}) {
  const [employeeId, setEmployeeId] = useState("");
  const [kind, setKind] = useState<"earning" | "deduction">("earning");
  const [label, setLabel] = useState("");
  const [amount, setAmount] = useState("");
  const [taxable, setTaxable] = useState(true);

  const prorata = employees.find((e) => e.id === employeeId)?.prorata ?? null;

  return (
    <PayrollToggleForm
      action={addPayrollAdjustmentAction}
      openLabel="Tambah Penyesuaian"
      submitLabel="Simpan Penyesuaian"
    >
      <input type="hidden" name="run_id" value={runId} />
      <label>
        Karyawan
        <select
          name="employee_id"
          required
          value={employeeId}
          onChange={(event) => setEmployeeId(event.target.value)}
        >
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

      {/* Pro-rata for a part month, worked out from this run's own figures and filled into the fields below,
          so the amount is never typed by hand (OWNER, 9 October 2026; decision 388). */}
      {prorata ? (
        <div className="prorata-card">
          <p className="prorata-lead">
            {prorata.reason} — bekerja {prorata.daysWorked} dari {prorata.daysInPeriod} hari bulan
            ini.
          </p>
          <dl className="prorata-figures">
            <div>
              <dt>Gaji sebulan penuh</dt>
              <dd>{formatMoney(prorata.grossPay, currency)}</dd>
            </div>
            <div>
              <dt>Gaji prorata</dt>
              <dd>{formatMoney(prorata.proratedGross, currency)}</dd>
            </div>
            <div className="prorata-cut">
              <dt>Potongan yang perlu dicatat</dt>
              <dd>{formatMoney(prorata.deduction, currency)}</dd>
            </div>
          </dl>
          <button
            type="button"
            className="btn-secondary"
            onClick={() => {
              setKind("deduction");
              setLabel(prorata.label);
              setAmount(prorata.deduction);
              // Pay that was never earned really is less income, so it lowers the PPh 21 base (decision 381).
              setTaxable(true);
            }}
          >
            Isi potongan prorata
          </button>
          <p className="hint">
            Dihitung per hari kalender. Kalau perusahaan memakai hari kerja, ubah jumlahnya sendiri.
          </p>
        </div>
      ) : null}

      <label>
        Jenis
        <select
          name="kind"
          value={kind}
          onChange={(event) => setKind(event.target.value as "earning" | "deduction")}
        >
          <option value="earning">Penghasilan (mis. bonus, lembur)</option>
          <option value="deduction">Potongan (mis. kasbon)</option>
        </select>
      </label>
      <label>
        Nama Penyesuaian
        <input
          name="label"
          required
          maxLength={120}
          value={label}
          onChange={(event) => setLabel(event.target.value)}
        />
      </label>
      <label>
        Jumlah
        <MoneyInput
          name="amount"
          required
          placeholder="0"
          value={amount}
          onValueChange={setAmount}
        />
      </label>
      <label className="checkbox-field">
        <input
          type="checkbox"
          name="taxable"
          checked={taxable}
          onChange={(event) => setTaxable(event.target.checked)}
        />{" "}
        {kind === "earning" ? "Dihitung untuk PPh 21" : "Mengurangi dasar PPh 21"}
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
  bpjsOutstanding,
}: {
  runId: string;
  accounts: readonly PayrollOption[];
  today: string;
  /** What is still owed to each BPJS body, already formatted (decision 277). */
  bpjsOutstanding: { kes: string; tk: string };
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
          <option value="bpjs_kes">Iuran BPJS Kesehatan (sisa {bpjsOutstanding.kes})</option>
          <option value="bpjs_tk">
            Iuran BPJS Ketenagakerjaan: JHT, JP, JKK, JKM (sisa {bpjsOutstanding.tk})
          </option>
        </select>
      </label>
      {kind !== "net_pay" ? (
        <label>
          Jumlah yang Dibayar (kosongkan untuk membayar seluruh sisa)
          <MoneyInput name="amount" placeholder="seluruh sisa" />
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
      <p className="hint">Perlu verifikasi ulang sebelum menyimpan pembayaran.</p>
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
      <p className="hint">Perlu verifikasi ulang sebelum membatalkan pembayaran.</p>
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
