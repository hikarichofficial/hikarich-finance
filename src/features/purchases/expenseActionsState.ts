import type { ExpenseActionState } from "./expenseActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleExpenseActionState: ExpenseActionState = { status: "idle" };
