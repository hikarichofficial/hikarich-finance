import type { BalanceAdjustmentFormState } from "./balanceAdjustmentActions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleBalanceAdjustmentFormState: BalanceAdjustmentFormState = { status: "idle" };
