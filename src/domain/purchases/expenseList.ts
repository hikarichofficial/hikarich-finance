import type { ExpenseRow, ExpenseStatus } from "@/schemas/expenses";

/**
 * Pure helpers for the Direct Expense screens (Step 09 §12, decision 245). The allowed transitions mirror
 * the P6 RPCs' own guards exactly (`20260924100200_p6_expenses.sql`); the database re-checks every one, this
 * only decides which buttons to show. Nothing here calls the database.
 */

export const EXPENSE_STATUS_LABELS: Readonly<Record<ExpenseStatus, string>> = {
  draft: "Draf",
  submitted: "Diajukan",
  confirmed: "Dikonfirmasi",
  reversed: "Dibalik",
  cancelled: "Dibatalkan",
};

export const EXPENSE_STATUS_TONE: Readonly<
  Record<ExpenseStatus, "neutral" | "progress" | "success">
> = {
  draft: "neutral",
  submitted: "progress",
  confirmed: "success",
  reversed: "neutral",
  cancelled: "neutral",
};

export const EXPENSE_FILTER_OPTIONS: readonly {
  readonly value: ExpenseStatus | undefined;
  readonly label: string;
}[] = [
  { value: undefined, label: "Semua" },
  ...(Object.keys(EXPENSE_STATUS_LABELS) as ExpenseStatus[]).map((value) => ({
    value,
    label: EXPENSE_STATUS_LABELS[value],
  })),
];

export function parseExpenseFilter(value: string | undefined): ExpenseStatus | undefined {
  return value !== undefined && Object.hasOwn(EXPENSE_STATUS_LABELS, value)
    ? (value as ExpenseStatus)
    : undefined;
}

export function expensePayeeLabel(
  row: ExpenseRow,
  vendorNames: ReadonlyMap<string, string>,
): string {
  if (row.payee_id) return vendorNames.get(row.payee_id) ?? row.payee_name ?? "—";
  return row.payee_name ?? "—";
}

export function filterExpenses(
  rows: readonly ExpenseRow[],
  status: ExpenseStatus | undefined,
  query: string,
  vendorNames: ReadonlyMap<string, string>,
): ExpenseRow[] {
  const q = query.trim().toLowerCase();
  return rows.filter((row) => {
    if (status && row.status !== status) return false;
    if (!q) return true;
    return (
      (row.expense_number ?? "").toLowerCase().includes(q) ||
      expensePayeeLabel(row, vendorNames).toLowerCase().includes(q) ||
      (row.receipt_reference ?? "").toLowerCase().includes(q)
    );
  });
}

export interface ExpensePermissions {
  canEdit: boolean; // bills.edit
  canSubmit: boolean; // bills.submit
  canPay: boolean; // bills.pay: confirm and reject
  canVoid: boolean; // bills.void
  canCreate: boolean; // bills.create
}

export interface ExpenseActionSet {
  submit: boolean;
  recall: boolean;
  reject: boolean;
  confirm: boolean;
  cancel: boolean;
  reverse: boolean;
  correct: boolean;
}

/** Which actions a person may attempt on an expense in `status`, by the P6 RPCs' own guards: submit a
 * draft (`bills.submit`); recall a submitted one (`bills.edit`); reject a submitted one or confirm a draft or
 * submitted one (`bills.pay`); cancel a draft (`bills.edit`) or a submitted one (`bills.void`); reverse a
 * confirmed one (`bills.void`); correct a confirmed one (`bills.void` and `bills.create`). */
export function expenseActions(status: ExpenseStatus, p: ExpensePermissions): ExpenseActionSet {
  return {
    submit: status === "draft" && p.canSubmit,
    recall: status === "submitted" && p.canEdit,
    reject: status === "submitted" && p.canPay,
    confirm: (status === "draft" || status === "submitted") && p.canPay,
    cancel: (status === "draft" && p.canEdit) || (status === "submitted" && p.canVoid),
    reverse: status === "confirmed" && p.canVoid,
    correct: status === "confirmed" && p.canVoid && p.canCreate,
  };
}
