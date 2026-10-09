"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { setFlash } from "@/lib/flash";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  addPayrollAdjustment,
  approvePayrollRun,
  calculatePayrollRun,
  closePayrollRun,
  correctPayrollRun,
  createEmployee,
  createPayrollRun,
  discardPayrollRun,
  endEmployee,
  postPayrollRun,
  recordEmployment,
  recordPayrollPayment,
  removePayrollAdjustment,
  reopenPayrollRun,
  returnPayrollRun,
  reversePayrollPayment,
  setBpjs,
  setCompensation,
  setTaxOpening,
  setTaxProfile,
  submitPayrollRun,
  updateEmployee,
} from "@/services/payroll/payroll";

/**
 * Server actions behind the Payroll write screens: employees (create, update, end, employment, compensation,
 * tax profile, BPJS, opening tax figures) and the payroll run (create, calculate, adjust, submit, approve,
 * return, discard, post, pay, close, reopen, correct). Every write is an unmodified P9 RPC; this layer only
 * shapes form input and maps `AuthzError` to user-safe copy, adding the database's own reason when it gives
 * one. The database decides who may act and in which status.
 */

export interface PayrollActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  /** The database asked for a fresh verification (step-up): the form offers the link to do it. */
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function checked(formData: FormData, name: string): boolean {
  return text(formData, name) === "on";
}

function errorState(error: unknown, fallback: string): PayrollActionState {
  if (error instanceof AuthzError) {
    return {
      status: "error",
      message: describeAuthzError(error),
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

function revalidateEmployee(employeeId: string): void {
  revalidatePath("/payroll/employees");
  revalidatePath(`/payroll/employees/${employeeId}`);
}

function revalidateRun(runId: string): void {
  revalidatePath("/payroll/runs");
  revalidatePath(`/payroll/runs/${runId}`);
  revalidatePath("/payroll/payslips");
}

// ================================================================ employees
export async function createEmployeeAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const entity = text(formData, "entity");
  let employeeId: string;
  try {
    const { membership } = await requirePermission("payroll.employee_edit", {
      entityCode: entity,
    });
    employeeId = await createEmployee({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      full_name: text(formData, "full_name"),
      join_date: text(formData, "join_date"),
      employment_type: text(formData, "employment_type") as never,
      position_title: text(formData, "position_title"),
      department: text(formData, "department") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Karyawan tidak dapat disimpan. Periksa nama, tanggal masuk dan jabatan.",
    );
  }
  revalidatePath("/payroll/employees");
  await setFlash("Karyawan tersimpan.");
  redirect(
    entity
      ? `/payroll/employees/${employeeId}?entity=${encodeURIComponent(entity)}`
      : `/payroll/employees/${employeeId}`,
  );
}

export async function updateEmployeeAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  try {
    await updateEmployee({
      employee_id: employeeId,
      full_name: text(formData, "full_name"),
      join_date: text(formData, "join_date") || undefined,
    });
  } catch (error) {
    return errorState(error, "Data karyawan tidak dapat diubah. Periksa nama dan tanggal masuk.");
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Data karyawan tersimpan." };
}

export async function endEmployeeAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  try {
    await endEmployee({
      employee_id: employeeId,
      idempotency_key: randomUUID(),
      exit_date: text(formData, "exit_date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Karyawan tidak dapat diberhentikan. Periksa tanggal berhenti dan alasan (minimal 5 huruf).",
    );
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Karyawan sudah ditandai berhenti." };
}

export async function recordEmploymentAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  try {
    await recordEmployment({
      employee_id: employeeId,
      effective_from: text(formData, "effective_from"),
      employment_type: text(formData, "employment_type") as never,
      position_title: text(formData, "position_title"),
      department: text(formData, "department") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Perubahan jabatan tidak dapat disimpan. Periksa tanggal dan jabatan.",
    );
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Perubahan jabatan tersimpan." };
}

export async function setCompensationAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  const rowCount = Math.min(Number(text(formData, "row_count")) || 0, 30);
  const items: {
    component: string;
    kind: never;
    label: string;
    amount: string;
    taxable: boolean;
    bpjs_base: boolean;
  }[] = [];
  for (let index = 0; index < rowCount; index += 1) {
    const label = text(formData, `label_${index}`);
    const amount = text(formData, `amount_${index}`);
    if (!label && !amount) continue;
    const kind = text(formData, `kind_${index}`);
    items.push({
      component: text(formData, `component_${index}`),
      kind: kind as never,
      label,
      amount,
      taxable: checked(formData, `taxable_${index}`),
      bpjs_base: kind === "earning" && checked(formData, `bpjs_base_${index}`),
    });
  }
  if (items.length === 0) {
    return { status: "error", message: "Isi minimal satu komponen gaji." };
  }
  try {
    await setCompensation({
      employee_id: employeeId,
      idempotency_key: randomUUID(),
      effective_from: text(formData, "effective_from"),
      items,
    });
  } catch (error) {
    return errorState(
      error,
      "Kompensasi tidak dapat disimpan. Periksa kode (huruf kecil tanpa spasi), nama dan jumlah tiap komponen.",
    );
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Kompensasi tersimpan." };
}

export async function setTaxProfileAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  try {
    await setTaxProfile({
      employee_id: employeeId,
      idempotency_key: randomUUID(),
      effective_from: text(formData, "effective_from"),
      tax_id_status: text(formData, "tax_id_status") as never,
      tax_id: text(formData, "tax_id") || undefined,
      ptkp_status: text(formData, "ptkp_status") as never,
      tax_method: text(formData, "tax_method") as never,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Data pajak tidak dapat disimpan. Nomor NPWP/NIK (15 atau 16 angka) diisi hanya bila statusnya punya NPWP/NIK.",
    );
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Data pajak karyawan tersimpan." };
}

const BPJS_COMPONENTS = ["bpjs_kes", "bpjs_jht", "bpjs_jp", "bpjs_jkk", "bpjs_jkm"] as const;

export async function setBpjsAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  const items: { component: never; enrolled: boolean; rate_key?: string; member_ref?: string }[] =
    [];
  for (const component of BPJS_COMPONENTS) {
    const choice = text(formData, `enrolled_${component}`);
    if (choice !== "yes" && choice !== "no") continue;
    items.push({
      component: component as never,
      enrolled: choice === "yes",
      rate_key: text(formData, `rate_key_${component}`) || undefined,
      member_ref: text(formData, `member_ref_${component}`) || undefined,
    });
  }
  if (items.length === 0) {
    return { status: "error", message: "Pilih minimal satu program BPJS yang diubah." };
  }
  try {
    await setBpjs({
      employee_id: employeeId,
      idempotency_key: randomUUID(),
      effective_from: text(formData, "effective_from"),
      items,
    });
  } catch (error) {
    return errorState(error, "Data BPJS tidak dapat disimpan. Periksa tanggal dan isian.");
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Data BPJS tersimpan." };
}

export async function setTaxOpeningAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const employeeId = text(formData, "employee_id");
  try {
    await setTaxOpening({
      employee_id: employeeId,
      idempotency_key: randomUUID(),
      tax_year: Number(text(formData, "tax_year")),
      through_month: Number(text(formData, "through_month")),
      taxable_gross: text(formData, "taxable_gross"),
      pension_deduction: text(formData, "pension_deduction") || "0",
      pph21_withheld: text(formData, "pph21_withheld"),
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Saldo awal pajak tidak dapat disimpan. Periksa tahun, bulan (1-11) dan jumlah.",
    );
  }
  revalidateEmployee(employeeId);
  return { status: "ok", message: "Saldo awal pajak tersimpan." };
}

// ================================================================ the run
export async function createPayrollRunAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const entity = text(formData, "entity");
  const month = text(formData, "period");
  let runId: string;
  try {
    const { membership } = await requirePermission("payroll.run", { entityCode: entity });
    runId = await createPayrollRun({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      period: month.length >= 7 ? `${month.slice(0, 7)}-01` : month,
      pay_date: text(formData, "pay_date"),
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Proses Payroll tidak dapat dibuat. Periksa bulan gaji dan tanggal bayar.",
    );
  }
  revalidatePath("/payroll/runs");
  await setFlash("Penggajian dibuat.");
  redirect(
    entity
      ? `/payroll/runs/${runId}?entity=${encodeURIComponent(entity)}`
      : `/payroll/runs/${runId}`,
  );
}

/** One action for the run's status commands; the hidden `command` field says which. */
export async function payrollRunCommandAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const runId = text(formData, "run_id");
  const command = text(formData, "command");
  const reason = text(formData, "reason");
  let message: string;
  try {
    switch (command) {
      case "calculate":
        await calculatePayrollRun(runId);
        message = "Payroll sudah dihitung.";
        break;
      case "submit":
        await submitPayrollRun({ run_id: runId, idempotency_key: randomUUID() });
        message = "Payroll diajukan untuk disetujui.";
        break;
      case "approve":
        await approvePayrollRun({ run_id: runId, idempotency_key: randomUUID() });
        message = "Payroll disetujui.";
        break;
      case "return":
        await returnPayrollRun({ run_id: runId, reason });
        message = "Payroll dikembalikan ke draf.";
        break;
      case "discard":
        await discardPayrollRun({ run_id: runId, reason });
        message = "Proses Payroll dibatalkan.";
        break;
      case "post":
        await postPayrollRun({ run_id: runId, idempotency_key: randomUUID() });
        message = "Payroll sudah diposting ke pembukuan.";
        break;
      case "close":
        await closePayrollRun({ run_id: runId, idempotency_key: randomUUID() });
        message = "Payroll ditutup.";
        break;
      case "reopen":
        await reopenPayrollRun({ run_id: runId, idempotency_key: randomUUID(), reason });
        message = "Payroll dibuka kembali.";
        break;
      case "correct":
        await correctPayrollRun({
          run_id: runId,
          idempotency_key: randomUUID(),
          date: text(formData, "date"),
          reason,
        });
        message = "Payroll dikoreksi. Revisi baru tersedia di daftar Proses Payroll.";
        break;
      default:
        return { status: "error", message: "Perintah tidak dikenali." };
    }
  } catch (error) {
    return errorState(
      error,
      command === "calculate"
        ? "Payroll tidak dapat dihitung. Periksa data karyawan (gaji, pajak, BPJS) lalu coba lagi."
        : "Perintah tidak dapat dijalankan. Periksa isian (alasan minimal 5 huruf) lalu coba lagi.",
    );
  }
  revalidateRun(runId);
  return { status: "ok", message };
}

export async function addPayrollAdjustmentAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const runId = text(formData, "run_id");
  try {
    await addPayrollAdjustment({
      run_id: runId,
      idempotency_key: randomUUID(),
      employee_id: text(formData, "employee_id"),
      kind: text(formData, "kind") as never,
      label: text(formData, "label"),
      amount: text(formData, "amount"),
      taxable: checked(formData, "taxable"),
    });
  } catch (error) {
    return errorState(
      error,
      "Penyesuaian tidak dapat disimpan. Periksa karyawan, nama dan jumlah (lebih dari nol).",
    );
  }
  revalidateRun(runId);
  return { status: "ok", message: "Penyesuaian tersimpan. Hitung ulang Payroll." };
}

export async function removePayrollAdjustmentAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const runId = text(formData, "run_id");
  try {
    await removePayrollAdjustment(text(formData, "adjustment_id"));
  } catch (error) {
    return errorState(error, "Penyesuaian tidak dapat dihapus.");
  }
  revalidateRun(runId);
  return { status: "ok", message: "Penyesuaian dihapus. Hitung ulang Payroll." };
}

export async function recordPayrollPaymentAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const runId = text(formData, "run_id");
  const kind = text(formData, "kind");
  try {
    await recordPayrollPayment({
      run_id: runId,
      idempotency_key: randomUUID(),
      kind: kind as never,
      date: text(formData, "date"),
      account_id: text(formData, "account_id"),
      amount: kind === "net_pay" ? undefined : text(formData, "amount") || undefined,
      reference: text(formData, "reference") || undefined,
      note: text(formData, "note") || undefined,
    });
  } catch (error) {
    return errorState(
      error,
      "Pembayaran tidak dapat disimpan. Periksa rekening, tanggal dan jumlah BPJS.",
    );
  }
  revalidateRun(runId);
  return { status: "ok", message: "Pembayaran tersimpan." };
}

export async function reversePayrollPaymentAction(
  _previous: PayrollActionState,
  formData: FormData,
): Promise<PayrollActionState> {
  const runId = text(formData, "run_id");
  try {
    await reversePayrollPayment({
      payment_id: text(formData, "payment_id"),
      idempotency_key: randomUUID(),
      date: text(formData, "date"),
      reason: text(formData, "reason"),
    });
  } catch (error) {
    return errorState(
      error,
      "Pembayaran tidak dapat dibatalkan. Periksa tanggal dan alasan (minimal 5 huruf).",
    );
  }
  revalidateRun(runId);
  return { status: "ok", message: "Pembayaran dibatalkan." };
}
