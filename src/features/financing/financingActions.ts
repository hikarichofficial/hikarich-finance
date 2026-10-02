"use server";

import { randomUUID } from "node:crypto";
import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { AuthzError, describeAuthzError } from "@/domain/authz/errors";
import { requirePermission } from "@/services/identity/access";
import {
  activateLoan,
  cancelEquityEvent,
  cancelLoan,
  confirmEquityEvent,
  createEquityEvent,
  createLoan,
  createObligation,
  payDividend,
  repayLoan,
  reverseDividendPayment,
  reverseEquityEvent,
  reverseLoanPayment,
  reverseObligationSettlement,
  settleObligation,
  voidObligation,
  writeOffLoan,
  writeOffObligation,
} from "@/services/financing/financing";

/**
 * Server actions behind the financing write screens: loans, other receivables/payables and equity events.
 * Every write is an unmodified P8 RPC (`loan_*`, `obligation_*`, `equity_*`); this layer only shapes form
 * input and maps `AuthzError` to user-safe copy, adding the database's own reason when it gives one. The
 * database still decides who may act, in which status, and when a recent re-verification is needed.
 */

export interface FinancingActionState {
  status: "idle" | "ok" | "error";
  message?: string;
  stepUp?: boolean;
}

function text(formData: FormData, name: string): string {
  const value = formData.get(name);
  return typeof value === "string" ? value.trim() : "";
}

function errorState(error: unknown, fallback: string): FinancingActionState {
  if (error instanceof AuthzError) {
    return {
      status: "error",
      message: describeAuthzError(error),
      stepUp: error.code === "STEP_UP_REQUIRED",
    };
  }
  return { status: "error", message: fallback };
}

function withEntity(path: string, entity: string): string {
  return entity ? `${path}?entity=${encodeURIComponent(entity)}` : path;
}

async function run(
  work: () => Promise<unknown>,
  fallback: string,
  paths: readonly string[],
  okMessage: string,
): Promise<FinancingActionState> {
  try {
    await work();
  } catch (error) {
    return errorState(error, fallback);
  }
  for (const path of paths) revalidatePath(path);
  return { status: "ok", message: okMessage };
}

function loanPaths(formData: FormData): string[] {
  return ["/assets/loans", `/assets/loans/${text(formData, "loan_id")}`];
}

function obligationPaths(formData: FormData): string[] {
  return [
    "/assets/other-receivables",
    "/assets/other-payables",
    `/assets/obligations/${text(formData, "obligation_id")}`,
  ];
}

function equityPaths(formData: FormData): string[] {
  return ["/assets/equity", `/assets/equity/${text(formData, "event_id")}`];
}

// ================================================================ loans
export async function createLoanAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  const entity = text(formData, "entity");
  const direction = text(formData, "direction");
  const termClass = text(formData, "term_class");
  let loanId: string;
  try {
    const { membership } = await requirePermission("loans.manage", { entityCode: entity });
    loanId = await createLoan({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      direction: direction as never,
      counterparty: text(formData, "counterparty"),
      purpose: text(formData, "purpose"),
      principal: text(formData, "principal"),
      agreement_date: text(formData, "agreement_date"),
      term_class: direction === "borrowed" && termClass ? (termClass as never) : undefined,
      rate_percent: text(formData, "rate_percent") || "0",
      method: text(formData, "method") as never,
      installments: Number(text(formData, "installments")),
      step_months: Number(text(formData, "step_months")) as never,
      first_due: text(formData, "first_due"),
    });
  } catch (error) {
    return errorState(
      error,
      "Pinjaman tidak dapat disimpan. Periksa jumlah, bunga, jumlah cicilan dan tanggal.",
    );
  }
  revalidatePath("/assets/loans");
  redirect(withEntity(`/assets/loans/${loanId}`, entity));
}

export async function activateLoanAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      activateLoan({
        loan_id: text(formData, "loan_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        account_id: text(formData, "account_id"),
      }),
    "Pinjaman tidak dapat diaktifkan. Periksa tanggal dan rekening.",
    loanPaths(formData),
    "Pinjaman aktif. Uang sudah dicatat.",
  );
}

export async function repayLoanAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      repayLoan({
        loan_id: text(formData, "loan_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        account_id: text(formData, "account_id"),
        principal: text(formData, "principal") || "0",
        interest: text(formData, "interest") || "0",
        fee: text(formData, "fee") || "0",
        note: text(formData, "note") || undefined,
      }),
    "Pembayaran cicilan tidak dapat disimpan. Periksa jumlah, tanggal dan rekening.",
    loanPaths(formData),
    "Pembayaran cicilan tersimpan.",
  );
}

export async function cancelLoanAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      cancelLoan({
        loan_id: text(formData, "loan_id"),
        idempotency_key: randomUUID(),
        reason: text(formData, "reason"),
      }),
    "Pinjaman tidak dapat dibatalkan. Isi alasan minimal 5 huruf.",
    loanPaths(formData),
    "Pinjaman dibatalkan.",
  );
}

export async function writeOffLoanAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      writeOffLoan({
        loan_id: text(formData, "loan_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        amount: text(formData, "amount"),
        reason: text(formData, "reason"),
      }),
    "Penghapusan tidak dapat disimpan. Periksa jumlah, tanggal dan alasan.",
    loanPaths(formData),
    "Penghapusan pinjaman tersimpan.",
  );
}

export async function reverseLoanPaymentAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      reverseLoanPayment({
        payment_id: text(formData, "payment_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        reason: text(formData, "reason"),
      }),
    "Pembayaran tidak dapat dibatalkan. Pilih pembayaran, lalu isi tanggal dan alasan.",
    loanPaths(formData),
    "Pembayaran dibatalkan.",
  );
}

// ================================================================ other receivables and payables
export async function createObligationAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  const entity = text(formData, "entity");
  let obligationId: string;
  try {
    const { membership } = await requirePermission("loans.manage", { entityCode: entity });
    obligationId = await createObligation({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      kind: text(formData, "kind") as never,
      counterparty: text(formData, "counterparty"),
      date: text(formData, "date"),
      due_date: text(formData, "due_date") || undefined,
      amount: text(formData, "amount"),
      method: "cash",
      account_id: text(formData, "account_id"),
      purpose: text(formData, "purpose"),
    });
  } catch (error) {
    return errorState(error, "Data tidak dapat disimpan. Periksa jumlah, tanggal dan rekening.");
  }
  revalidatePath("/assets/other-receivables");
  revalidatePath("/assets/other-payables");
  redirect(withEntity(`/assets/obligations/${obligationId}`, entity));
}

export async function settleObligationAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      settleObligation({
        obligation_id: text(formData, "obligation_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        account_id: text(formData, "account_id"),
        principal: text(formData, "principal"),
        interest: text(formData, "interest") || "0",
        fee: text(formData, "fee") || "0",
        note: text(formData, "note") || undefined,
      }),
    "Pelunasan tidak dapat disimpan. Periksa jumlah, tanggal dan rekening.",
    obligationPaths(formData),
    "Pelunasan tersimpan.",
  );
}

export async function voidObligationAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      voidObligation({
        obligation_id: text(formData, "obligation_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        reason: text(formData, "reason"),
      }),
    "Data tidak dapat dibatalkan. Isi tanggal dan alasan minimal 5 huruf.",
    obligationPaths(formData),
    "Data dibatalkan.",
  );
}

export async function writeOffObligationAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      writeOffObligation({
        obligation_id: text(formData, "obligation_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        amount: text(formData, "amount"),
        reason: text(formData, "reason"),
      }),
    "Penghapusan tidak dapat disimpan. Periksa jumlah, tanggal dan alasan.",
    obligationPaths(formData),
    "Penghapusan tersimpan.",
  );
}

export async function reverseObligationSettlementAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      reverseObligationSettlement({
        settlement_id: text(formData, "settlement_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        reason: text(formData, "reason"),
      }),
    "Pelunasan tidak dapat dibatalkan. Pilih pelunasan, lalu isi tanggal dan alasan.",
    obligationPaths(formData),
    "Pelunasan dibatalkan.",
  );
}

// ================================================================ equity
export async function createEquityEventAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  const entity = text(formData, "entity");
  const kind = text(formData, "kind");
  const hasClass = kind === "contribution" || kind === "capital_return";
  let eventId: string;
  try {
    const { membership } = await requirePermission("equity.manage", { entityCode: entity });
    eventId = await createEquityEvent({
      entity_id: membership.entity_id,
      idempotency_key: randomUUID(),
      kind: kind as never,
      date: text(formData, "date"),
      amount: text(formData, "amount"),
      counterparty: text(formData, "counterparty"),
      purpose: text(formData, "purpose"),
      equity_class: hasClass ? ((text(formData, "equity_class") || "capital") as never) : undefined,
      resolution_reference: text(formData, "resolution_reference") || undefined,
    });
  } catch (error) {
    return errorState(error, "Data tidak dapat disimpan. Periksa jumlah, tanggal dan keterangan.");
  }
  revalidatePath("/assets/equity");
  redirect(withEntity(`/assets/equity/${eventId}`, entity));
}

export async function confirmEquityEventAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      confirmEquityEvent({
        event_id: text(formData, "event_id"),
        idempotency_key: randomUUID(),
        account_id: text(formData, "account_id") || undefined,
      }),
    "Data tidak dapat dikonfirmasi. Periksa rekening.",
    equityPaths(formData),
    "Data dikonfirmasi dan dicatat.",
  );
}

export async function cancelEquityEventAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      cancelEquityEvent({
        event_id: text(formData, "event_id"),
        idempotency_key: randomUUID(),
        reason: text(formData, "reason"),
      }),
    "Data tidak dapat dibatalkan. Isi alasan minimal 5 huruf.",
    equityPaths(formData),
    "Data dibatalkan.",
  );
}

export async function reverseEquityEventAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      reverseEquityEvent({
        event_id: text(formData, "event_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        reason: text(formData, "reason"),
      }),
    "Data tidak dapat dibalik. Isi tanggal dan alasan minimal 5 huruf.",
    equityPaths(formData),
    "Data dibalik.",
  );
}

export async function payDividendAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      payDividend({
        event_id: text(formData, "event_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        account_id: text(formData, "account_id"),
        amount: text(formData, "amount"),
        note: text(formData, "note") || undefined,
      }),
    "Pembayaran dividen tidak dapat disimpan. Periksa jumlah, tanggal dan rekening.",
    equityPaths(formData),
    "Pembayaran dividen tersimpan.",
  );
}

export async function reverseDividendPaymentAction(
  _previous: FinancingActionState,
  formData: FormData,
): Promise<FinancingActionState> {
  return run(
    () =>
      reverseDividendPayment({
        payment_id: text(formData, "payment_id"),
        idempotency_key: randomUUID(),
        date: text(formData, "date"),
        reason: text(formData, "reason"),
      }),
    "Pembayaran dividen tidak dapat dibatalkan. Pilih pembayaran, lalu isi tanggal dan alasan.",
    equityPaths(formData),
    "Pembayaran dividen dibatalkan.",
  );
}
