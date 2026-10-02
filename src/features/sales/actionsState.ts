import type { CorrectInvoiceState, InvoiceActionState, InvoiceLinkState } from "./actions";

/** Initial form states. They live outside the "use server" file, which may export only async functions. */
export const idleInvoiceActionState: InvoiceActionState = { status: "idle" };
export const idleCorrectInvoiceState: CorrectInvoiceState = { status: "idle" };
export const idleInvoiceLinkState: InvoiceLinkState = { status: "idle" };
export const idleReversePaymentState: InvoiceActionState = { status: "idle" };
