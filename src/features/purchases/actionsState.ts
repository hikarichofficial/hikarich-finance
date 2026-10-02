import type { BillActionState, CorrectBillState } from "./actions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleBillActionState: BillActionState = { status: "idle" };
export const idleCorrectBillState: CorrectBillState = { status: "idle" };
export const idleReverseVendorPaymentState: BillActionState = { status: "idle" };
